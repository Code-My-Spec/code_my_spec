defmodule CodeMySpec.DurableRun do
  @moduledoc """
  The record a harness keeps of each test run it starts, so that the next
  harness, after a restart, can claim the run and answer it.

  The run itself carries everything else: it is a node linked to the harness
  (`ClientUtils.RunLink`), holds its events until a harness acknowledges them,
  rejoins whichever harness serves it after a restart, and writes its results
  and output to the paths named here. The record says which run to claim
  (`run_id`, `root`), which node it is (to tell a dead run from one yet to
  rejoin), and, once answered, the payloads the server has yet to acknowledge.
  """

  use Boundary, top_level?: true, deps: [CodeMySpec.Paths], exports: :all

  alias CodeMySpec.Paths

  @session "client_utils/lib/client_utils/run_link/session.ex"
  @session_beam "client_utils/ebin/Elixir.ClientUtils.RunLink.Session.beam"

  @spec dir() :: String.t()
  def dir, do: Path.join(Paths.local_state_dir(), "runs")
  def manifest_path(id) when is_integer(id), do: Path.join(dir(), "#{id}.json")
  def output_path(id) when is_integer(id), do: Path.join(dir(), "#{id}.output")

  @doc "Where the run writes its results (`.json` for exunit, `.jsonl` for spex)."
  def results_path(id, extension) when is_integer(id), do: Path.join(dir(), "#{id}#{extension}")

  @doc """
  Whether the project at `root` links its runs to the harness (client_utils
  0.4.0+): in its fetched deps, or, for a path dep, in the analyzer's build of
  it (`MIX_BUILD_PATH` takes no env suffix).
  """
  @spec links?(String.t()) :: boolean()
  def links?(root) do
    File.exists?(Path.join([root, "deps", @session])) or
      File.exists?(Path.join([root, "_build/analyzer/lib", @session_beam]))
  end

  def begin_run(id, root, source, args, commit, tied_run_ids \\ []) when is_integer(id) do
    File.mkdir_p!(dir())
    File.write!(output_path(id), "")

    manifest = %{
      "run_id" => id,
      "root" => root,
      "source" => source,
      "args" => args,
      "tied_run_ids" => tied_run_ids,
      "start_commit" => commit,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "status" => "running"
    }

    write_manifest(manifest)
    manifest
  end

  def read_manifest(id) do
    with {:ok, data} <- File.read(manifest_path(id)),
         {:ok, %{} = manifest} <- Jason.decode(data) do
      {:ok, manifest}
    end
  end

  def update(id, fields) when is_integer(id) and is_map(fields) do
    with {:ok, manifest} <- read_manifest(id) do
      manifest |> Map.merge(fields) |> write_manifest()
    end
  end

  def for_root(root) do
    case File.ls(dir()) do
      {:ok, names} ->
        for name <- names,
            String.ends_with?(name, ".json"),
            {id, ".json"} <- [Integer.parse(name)],
            {:ok, manifest} <- [read_manifest(id)],
            manifest["root"] == root,
            manifest["status"] in ["running", "completed"],
            do: manifest

      {:error, _} ->
        []
    end
  end

  @doc """
  Whether `pid` is a running durable run's process or one of its children, so
  that `CodeMySpec.RunGuard` leaves it to outlive its harness.
  """
  def protected_pid?(pid, root_dir \\ dir()) when is_integer(pid) do
    case File.ls(root_dir) do
      {:ok, names} ->
        Enum.any?(names, fn name ->
          case Integer.parse(name) do
            {_id, ".json"} ->
              with {:ok, data} <- File.read(Path.join(root_dir, name)),
                   {:ok, %{"status" => "running", "pid" => run}} <- Jason.decode(data) do
                run == pid or descendant_of?(pid, run)
              else
                _ -> false
              end

            _ ->
              false
          end
        end)

      {:error, _} ->
        false
    end
  end

  def complete(manifest, payloads) do
    updated = manifest |> Map.put("status", "completed") |> Map.put("payloads", payloads)
    write_manifest(updated)
    updated
  end

  def acknowledge(manifest, run_id) do
    ids = [manifest["run_id"] | manifest["tied_run_ids"] || []]
    acknowledged = Enum.uniq([run_id | manifest["acknowledged_run_ids"] || []])

    if Enum.all?(ids, &(&1 in acknowledged)) do
      cleanup(manifest["run_id"])
      :complete
    else
      updated = Map.put(manifest, "acknowledged_run_ids", acknowledged)
      write_manifest(updated)
      {:pending, updated}
    end
  end

  def unacknowledged_payloads(manifest) do
    acknowledged = manifest["acknowledged_run_ids"] || []
    Enum.reject(manifest["payloads"] || [], &(&1["run_id"] in acknowledged))
  end

  def cleanup(id) do
    File.rm(manifest_path(id))
    File.rm(output_path(id))
    Enum.each(Path.wildcard(output_path(id) <> ".shard-*"), &File.rm/1)
    File.rm(results_path(id, ".json"))
    File.rm(results_path(id, ".jsonl"))
    :ok
  end

  defp write_manifest(manifest),
    do: write_atomically(manifest_path(manifest["run_id"]), Jason.encode!(manifest))

  defp write_atomically(path, contents) do
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, contents)
    File.rename!(tmp, path)
    :ok
  end

  # RunGuard's own platform (it does not run on Windows).
  defp descendant_of?(pid, ancestor), do: descendant_of?(pid, ancestor, 16)

  defp descendant_of?(_pid, _ancestor, 0), do: false

  defp descendant_of?(pid, ancestor, remaining) when is_integer(pid) and pid > 1 do
    case System.cmd("/bin/ps", ["-o", "ppid=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {parent, 0} ->
        case Integer.parse(String.trim(parent)) do
          {^ancestor, ""} -> true
          {next, ""} when next > 1 -> descendant_of?(next, ancestor, remaining - 1)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp descendant_of?(_pid, _ancestor, _remaining), do: false
end
