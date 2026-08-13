defmodule CodeMySpec.Tests do
  @moduledoc """
  Tests context for executing and parsing ExUnit test results.
  Provides a clean functional interface for test execution and result analysis.
  """

  require Logger

  alias CodeMySpec.Environments

  alias CodeMySpec.Tests.TestRun

  @doc """
  Execute mix test synchronously and parse results.

  ## Parameters

  - `args` - List of arguments to pass to mix test (e.g., ["test/my_test.exs", "--only", "integration"])
  - `opts` - Keyword list of options:
    - `:environment` - Environment to run tests in (required); commands run in its cwd
    - `:output_file` - Path for test results JSON (optional, defaults to temp file)

  ## Returns

  `{:ok, %TestRun{}}` - Parsed test run with stats, failures, etc.
  `{:error, {:parse_error, raw_output}}` - If JSON parsing fails

  ## Example

      {:ok, test_run} = Tests.execute(["test/my_test.exs"], environment: env)
      test_run.stats.failures  # => 0
  """
  @spec execute(args :: [String.t()], opts :: keyword()) ::
          {:ok, TestRun.t()} | {:error, {:parse_error, String.t()}}
  def execute(args, opts \\ []) do
    env = Keyword.fetch!(opts, :environment)

    temp_file =
      Keyword.get_lazy(opts, :output_file, fn ->
        CodeMySpec.TempFile.path("test_output", ".json")
      end)

    test_args = ["test", "--formatter", "ClientUtils.TestFormatter" | args]
    command = "mix " <> Enum.join(test_args, " ")
    file_path = extract_file_path(args)

    # clean_otp_env clears the Burrito release's ROOTDIR/BINDIR/RELEASE_* so
    # the child `mix`/`erl` boots from the user's installed OTP, not our
    # extracted ERTS ("cannot get bootfile"). Appended last so it wins.
    extra_env = Keyword.get(opts, :extra_env, [])

    # `merge_clean_env/1`, never `++ clean_otp_env()`. The scrub sets MIX_ENV to
    # nil, so appending it last unsets the "test" set two lines above.
    #
    # `mix test` happens to survive that — Mix forces test env for its own task —
    # which is exactly what made it survivable here for so long. The ecto tasks
    # that used to run alongside it did not, and migrated `code_my_spec_dev`.
    # They are gone now, and this stays correct so the next thing added here
    # inherits a working environment rather than the trap.
    cmd_env =
      Environments.merge_clean_env(
        env:
          [{"MIX_ENV", "test"}, {"EXUNIT_JSON_OUTPUT_FILE", temp_file}] ++
            partition_env(env, extra_env) ++ extra_env
      )[:env]

    Logger.info("[Tests] Running: #{command}")

    # Track whether we're using a caller-provided file (cache) vs a generated temp file
    caller_provided_file = Keyword.has_key?(opts, :output_file)

    case run_with_database(env, test_args, cmd_env) do
      {raw_output, exit_code} ->
        json_content = read_test_results(env, temp_file, caller_provided_file)

        parse_test_results(json_content, %{
          file_path: file_path,
          command: command,
          exit_code: exit_code,
          raw_output: raw_output,
          ran_at: DateTime.utc_now()
        })
    end
  rescue
    exception ->
      Logger.error("[Tests] Execution error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  # The analyzer gets its own test database, because otherwise it shares the
  # agent's.
  #
  # `config/test.exs` already partitions per working copy, so two worktrees are
  # separate. What was not separate is the analyzer from the agent *inside* one
  # worktree: this ran with `cd:` set to the working copy and no
  # `MIX_TEST_PARTITION`, so it resolved to exactly the database the agent's own
  # `mix test` uses, and every analyzer pass became a second writer on the same
  # sandbox.
  #
  # The symptom is a set of `MatchError`s on fixture setup, in whatever files
  # happened to be running — never the ones the agent changed. It blocked five
  # consecutive stops here. Deleting the rows did not help: a second collided
  # run replaced them within eight minutes. And it does not need an agent
  # running tests at all — several sessions' analyzers collide with each other,
  # which is why timing mitigations cannot work.
  #
  # Yield to a caller that already isolated the database.
  #
  # The harness path does: `CmsHarness.AnalyzerEnv.extra_env/1` includes
  # `CmsHarness.TestDatabase.env/1`, which derives a partition from the
  # absolute path and ensures the database exists — the
  # `code_my_spec_testh<hash>` databases. Setting a second value here and
  # relying on `System.cmd`'s duplicate-key ordering to pick the right one
  # would be a coin flip dressed as a fix.
  #
  # What is left uncovered is the server-side path, which calls this with no
  # `extra_env` at all and therefore inherits the working copy's own test
  # database — the same one the agent's `mix test` uses. That is the collision.
  defp partition_env(env, extra_env) do
    if List.keymember?(extra_env, "MIX_TEST_PARTITION", 0),
      do: [],
      else: [{"MIX_TEST_PARTITION", partition(env)}]
  end

  # One database per working copy, created once and reused. A unique name per
  # run would be perfectly isolated and would also mean creating and migrating
  # a database on every stop.
  #
  # Derived from the working copy, not a bare suffix. `config/test.exs` uses
  # `MIX_TEST_PARTITION` *instead of* its own per-worktree name when set, so a
  # constant here would give every worktree's analyzer one shared
  # `code_my_spec_test_analyzer` — four agents' analyzers colliding with each
  # other, which is the worse version of the bug being fixed.
  @analyzer_partition "_analyzer"

  defp partition(%{cwd: cwd}) when is_binary(cwd) and cwd != "",
    do: "_" <> Path.basename(cwd) <> @analyzer_partition

  defp partition(_env) do
    case System.get_env("MIX_TEST_PARTITION") do
      value when is_binary(value) and value != "" -> value <> @analyzer_partition
      _ -> @analyzer_partition
    end
  end

  # No creating, no migrating. This used to notice "database does not exist",
  # shell out to `ecto.create` and `ecto.migrate`, and retry.
  #
  # `Environments.clean_otp_env/0` scrubbed MIX_ENV out of `cmd_env`, and unlike
  # `mix test` — which forces test env for itself — the ecto tasks inherit
  # whatever they are given. So they ran in **dev** and migrated
  # `code_my_spec_dev`, the database every agent shares. That is how a
  # DropStatusFromStories migration reached dev at 03:34 on 2026-08-13 with
  # nobody having run one there.
  #
  # Removed rather than repaired. Nothing in this project may migrate a
  # database from code — `Mix.Tasks.Cms.CheckTestMigrations` already holds that
  # line, "a refusal rather than an alias that migrates", and this was the
  # exception. A missing database now surfaces as the child's own "database
  # does not exist", which names itself and is answered by a human with
  # `MIX_ENV=test mix ecto.create`.
  defp run_with_database(env, test_args, cmd_env) do
    Environments.cmd(env, "mix", test_args, stderr_to_stdout: true, env: cmd_env)
  end



  # A generated temp path is handed to the child as `EXUNIT_JSON_OUTPUT_FILE`,
  # so the child writes it wherever it is running — inside the environment.
  # Reading it back with File.read looked on the machine that *launched* the run,
  # and the miss is silent: "{}" parses as a run with no tests, which is
  # indistinguishable from a clean suite. A sprite whose tests all failed
  # reported green.
  #
  # A caller-provided path is the cassette seam (the stop hook's
  # `test_output_files`), which is a fixture on the harness's own disk — host
  # local, and not ours to delete.
  defp read_test_results(env, temp_file, caller_provided_file) do
    read =
      if caller_provided_file,
        do: File.read(temp_file),
        else: Environments.read_file(env, temp_file)

    result =
      case read do
        {:ok, content} ->
          content

        {:error, reason} ->
          Logger.warning("Failed to read test results file #{temp_file}: #{inspect(reason)}")
          "{}"
      end

    unless caller_provided_file, do: Environments.delete_file(env, temp_file)
    result
  end

  defp extract_file_path(args) do
    Enum.find(args, "unknown", fn arg ->
      String.contains?(arg, "/") or String.ends_with?(arg, ".exs") or
        String.ends_with?(arg, ".ex")
    end)
  end

  defp parse_test_results(json_string, metadata) do
    case Jason.decode(json_string) do
      {:ok, data} ->
        build_test_run(data, metadata)

      {:error, _} ->
        {:error, {:parse_error, json_string}}
    end
  end

  defp build_test_run(data, metadata) do
    execution_status = determine_execution_status(data, metadata.exit_code)

    attrs =
      data
      |> Map.merge(%{
        "file_path" => metadata.file_path,
        "command" => metadata.command,
        "exit_code" => metadata.exit_code,
        "execution_status" => execution_status,
        "raw_output" => metadata.raw_output,
        "ran_at" => metadata.ran_at
      })

    changeset = TestRun.parse_changeset(%TestRun{}, attrs)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      errors =
        Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
          "#{field}: #{message}"
        end)

      Logger.warning("Failed to build TestRun: #{errors}")
      {:error, {:parse_error, "Invalid test run data: #{errors}"}}
    end
  end

  defp determine_execution_status(data, exit_code) do
    cond do
      exit_code == 0 -> :success
      get_in(data, ["stats", "failures"]) && get_in(data, ["stats", "failures"]) > 0 -> :failure
      exit_code != nil && exit_code != 0 -> :error
      true -> :error
    end
  end
end
