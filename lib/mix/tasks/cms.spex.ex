defmodule Mix.Tasks.Cms.Spex do
  @shortdoc "Run spex; the whole suite runs as parallel shards"

  @moduledoc """
  What this repo's `just spex` runs, and so what the CodeMySpec gate runs.

  Named files go to `mix spex` exactly as before. The whole suite — no files
  named — runs as four child processes, each on its own copy of this partition's
  migrated database, and their JSONL and exit codes are merged. Nearly every spex
  is sync, so a single run uses one core; separate VMs on separate databases keep
  each shard's global state its own.

  Measured 2026-10-14: 141s for four shards against 390–480s for one run, 1763
  tests, 0 failures. Eight shards were no faster on a 10-core box.

  A shard's database is `<this database>_<n>`, recreated from this one as a
  template every run, so a migration an earlier candidate applied cannot linger
  in it, and with its sequences back at 1 — the small ids the gate's fresh
  databases have, which is where an id read as a criterion number first showed
  (892). When the template is busy (another run is connected to it) the shard is
  created empty and its own `mix spex` alias migrates it.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  @shards 4
  @prefix "code_my_spec_test"
  @reset_sequences "SELECT setval(c.oid, 1, false) FROM pg_class c WHERE c.relkind = 'S'"

  @impl Mix.Task
  def run(args) do
    # Backstop for stub dirs a killed run never got to clean up itself --
    # this host's $TMPDIR (System.tmp_dir!/0) is shared by every working
    # copy that runs this task. 1 hour stays well above
    # CodeMySpec.Analysis.ProjectServer's own 30-minute @job_timeout, the
    # ceiling that kills a run before it could still legitimately be here.
    CodeMySpec.TempFile.sweep_stale("spex", :timer.hours(1))
    CodeMySpec.TempFile.sweep_orphans(:timer.minutes(10))
    Mix.Task.run("compile")
    {files, jsonl, formatters, rest} = split_args(args)

    if files == [] and rest == [] do
      run_shards(jsonl, formatters)
    else
      run_here(args)
    end
  end

  defp run_here(args) do
    refuse_unless_own_shard!()
    Mix.Task.run("spex", args)
  end

  # `--formatter=…` goes to every shard, so a run the harness watches still shards.
  defp split_args(args) do
    {jsonl, others} = Enum.split_with(args, &String.starts_with?(&1, "--jsonl="))
    {formatters, others} = Enum.split_with(others, &String.starts_with?(&1, "--formatter="))
    {files, rest} = Enum.split_with(others, &String.ends_with?(&1, ".exs"))

    {files, Enum.map(jsonl, &String.replace_prefix(&1, "--jsonl=", "")) |> List.first(),
     formatters, rest}
  end

  defp run_shards(jsonl, formatters) do
    # The template has to be current; these are the `spex` alias's own first steps.
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    base = database()
    partition = String.replace_prefix(base, @prefix, "")
    groups = groups()

    Mix.shell().info("[cms.spex] #{length(spex_files())} files in #{@shards} shards")
    with_admin(fn conn -> Enum.each(1..@shards, &recreate(conn, base, shard_db(base, &1))) end)

    results =
      groups
      |> Enum.with_index(1)
      |> Task.async_stream(&run_shard(&1, partition, formatters),
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, result} -> result end)

    Enum.each(results, fn {i, _status, output, _jsonl} ->
      Mix.shell().info("\n===== shard #{i} =====\n" <> output)
    end)

    if jsonl, do: File.write!(jsonl, Enum.map_join(results, &read_jsonl/1))
    Enum.each(results, fn {_, _, _, path} -> File.rm(path) end)

    statuses = Enum.map(results, fn {i, status, _, _} -> "shard #{i}: exit #{status}" end)
    Mix.shell().info("[cms.spex] " <> Enum.join(statuses, ", "))

    if Enum.any?(results, fn {_, status, _, _} -> status != 0 end), do: exit({:shutdown, 1})
  end

  defp run_shard({files, i}, partition, formatters) do
    path =
      Path.join(System.tmp_dir!(), "cms_spex_shard_#{System.unique_integer([:positive])}.jsonl")

    started = System.monotonic_time(:second)

    {output, status} =
      System.cmd("mix", ["cms.spex" | files] ++ formatters ++ ["--jsonl=#{path}"],
        env:
          [{"MIX_ENV", "test"}, {"MIX_TEST_PARTITION", "#{partition}_#{i}"}] ++ run_link_env(i),
        stderr_to_stdout: true
      )

    Mix.shell().info(
      "[cms.spex] shard #{i} exited #{status} in #{System.monotonic_time(:second) - started}s"
    )

    {i, status, output, path}
  end

  @doc false
  # A run the harness watches names this BEAM a node (`ELIXIR_ERL_OPTIONS`).
  # Each shard joins it as a node of its own, so each needs its own name, and
  # is told it is a shard: the run finishes when this task exits, not when the
  # first shard does.
  def run_link_env(i, options \\ System.get_env("ELIXIR_ERL_OPTIONS")) do
    case options && Regex.run(~r/-name (\S+)@/, options) do
      [_, name] ->
        [
          {"ELIXIR_ERL_OPTIONS",
           String.replace(options, "-name #{name}@", "-name #{name}_s#{i}@")},
          {"CMS_RUN_SHARDS", Integer.to_string(@shards)}
        ]

      _ ->
        []
    end
  end

  defp read_jsonl({_, _, _, path}) do
    case File.read(path) do
      {:ok, ""} -> ""
      {:ok, content} -> String.trim_trailing(content, "\n") <> "\n"
      {:error, _} -> ""
    end
  end

  # Round-robin over the sorted list, so one story's criteria spread across shards.
  defp groups do
    spex_files()
    |> Enum.with_index()
    |> Enum.group_by(fn {_, i} -> rem(i, @shards) end, fn {file, _} -> file end)
    |> Enum.sort()
    |> Enum.map(fn {_, files} -> files end)
  end

  defp spex_files do
    Mix.Project.config()
    |> get_in([:spex, :pattern])
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp shard_db(base, i), do: "#{base}_#{i}"

  defp recreate(conn, base, shard) do
    guard!(shard)
    Postgrex.query!(conn, ~s[DROP DATABASE IF EXISTS "#{shard}" WITH (FORCE)], [])

    case Postgrex.query(conn, ~s[CREATE DATABASE "#{shard}" TEMPLATE "#{base}"], []) do
      {:ok, _} ->
        with_admin(shard, &Postgrex.query!(&1, @reset_sequences, []))

      {:error, %Postgrex.Error{postgres: %{code: :object_in_use}}} ->
        Postgrex.query!(conn, ~s[CREATE DATABASE "#{shard}"], [])
    end
  end

  # Only ever this repo's test databases.
  defp guard!(name) do
    unless String.starts_with?(name, @prefix) and name =~ ~r/_\d+$/ do
      Mix.raise("[cms.spex] refusing to recreate #{inspect(name)}: not a spex shard database")
    end
  end

  defp with_admin(database \\ "postgres", fun) do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    config = CodeMySpec.Repo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port] || 5432,
        username: config[:username],
        password: config[:password],
        database: database
      )

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  # A shard that resolved to some other database would share it with its
  # siblings and fail as if the suite were broken.
  defp refuse_unless_own_shard! do
    with "" <> requested <- System.get_env("MIX_TEST_PARTITION"),
         true <- requested =~ ~r/_\d+$/,
         false <- String.ends_with?(database(), requested) do
      Mix.raise(
        "[cms.spex] MIX_TEST_PARTITION=#{requested} resolved to #{database()}; " <>
          "config/test.exs did not accept it as this copy's shard"
      )
    else
      _ -> :ok
    end
  end

  defp database, do: CodeMySpec.Repo.config()[:database]
end
