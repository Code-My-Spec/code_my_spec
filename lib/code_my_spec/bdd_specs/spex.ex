defmodule CodeMySpec.BddSpecs.Spex do
  @moduledoc """
  Executes Spex BDD specifications via `mix spex` and returns structured results.
  Wraps command execution with JSONL output parsing, capturing scenario pass/fail
  status and step-level failure details.
  """

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  alias CodeMySpec.BddSpecs.Spex.{Error, Failure, Step}

  @doc """
  Execute mix spex synchronously and parse results.

  ## Parameters

  - `args` - List of arguments to pass to mix spex (e.g., ["test/spex/login_spex.ex"])
  - `opts` - Keyword list of options:
    - `:environment` - Environment to run specs in (required); commands run in its cwd
    - `:quiet` - Suppress console output (default: false)
    - `:jsonl_path` - Custom path for JSONL output file (defaults to temp file)

  ## Returns

  `{:ok, failures, exit_code, raw_output}` - Parsed failures, exit code, and
  everything `mix spex` printed. The output matters on the path where there are
  no failures *and* a nonzero exit: that combination means the suite did not
  run, and the output is the only account of why.
  `{:error, {:parse_error, reason}}` - If JSONL parsing fails

  ## Example

      {:ok, failures, exit_code, _output} =
        Spex.execute(["test/spex/login_spex.ex"], environment: env)

      exit_code  # => 0 for success, non-zero for failure
  """
  @spec execute(args :: [String.t()], opts :: keyword()) ::
          {:ok, [Failure.t()], integer(), String.t()}
          | {:error, {:parse_error, String.t()}}
  def execute(args, opts \\ []) do
    environment = Keyword.fetch!(opts, :environment)
    project_root = environment.cwd
    quiet = Keyword.get(opts, :quiet, false)

    caller_provided_file =
      Keyword.has_key?(opts, :output_file) or Keyword.has_key?(opts, :jsonl_path)

    temp_file =
      Keyword.get(
        opts,
        :output_file,
        Keyword.get(
          opts,
          :jsonl_path,
          CodeMySpec.TempFile.path("spex_output", ".jsonl")
        )
      )

    if replay_only?(opts) do
      replay(Keyword.fetch!(opts, :output_file), environment)
    else
      shell_out(args, opts, environment, project_root, quiet, temp_file, caller_provided_file)
    end
  rescue
    exception ->
      Logger.error("[Spex] Execution error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  # `:output_file` is the test-only escape hatch — the caller has already
  # supplied the run's JSONL, so there is nothing for a subprocess to
  # produce. Shelling out anyway meant the exit code came from an
  # ExCliVcr recording rather than from the results in hand, which made a
  # *passing* spex run unsimulatable: every stop-hook cassette records
  # `mix spex --jsonl=*` at exit 1, so supplying an empty (green) JSONL
  # tripped `runners.ex`'s `{:ok, [], exit_code != 0}` "suite did not run"
  # guard.
  #
  # Same shape the Credo analyzer already uses for its own
  # `:output_file` short-circuit. Exit status is derived from the parsed
  # failures, which is the thing the caller actually cares about.
  defp replay_only?(opts), do: Keyword.has_key?(opts, :output_file)

  # `nil` env on purpose: a caller-provided output file is a real path on
  # the host disk, not something inside the project's (possibly in-memory)
  # environment. Same choice `parse_and_return_failures/4` makes.
  defp replay(output_file, _environment) do
    case parse_jsonl(output_file, nil) do
      {:ok, failures} ->
        Logger.info("[Spex] Replaying #{length(failures)} failure(s) from #{output_file}")
        # Empty output, and honestly so: nothing was shelled out, so there is
        # nothing `mix spex` printed. The fourth element exists for the
        # suite-did-not-run diagnosis, and this path cannot reach it — the exit
        # status is derived from the parsed failures rather than observed.
        {:ok, failures, if(failures == [], do: 0, else: 1), ""}

      {:error, reason} ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end

  defp shell_out(args, opts, environment, project_root, quiet, temp_file, caller_provided_file) do
    args = expand_directory_args(args, project_root, environment)
    spex_args = build_args(args, temp_file, quiet)
    command = "mix " <> Enum.join(spex_args, " ")

    # clean_otp_env keeps the child `mix`/`erl` off our Burrito ERTS (see
    # CodeMySpec.Environments.clean_otp_env/0).
    # `extra_env` is how the harness hands over `MIX_TEST_PARTITION`, and it
    # carries the guarantee that the database exists — `TestDatabase.env/1`
    # creates and migrates before returning the name. Without it a spex run
    # falls back to whatever `config/test.exs` derives, which is the right name
    # for a database nothing has created, and Postgrex answers
    # `invalid_catalog_name` six frames below a sandbox error that names the
    # spec file. "2 tests, 2 failures" with no mention of a database is how an
    # agent ends up editing specs that were never wrong.
    cmd_env =
      [{"MIX_ENV", "test"}] ++
        Keyword.get(opts, :extra_env, []) ++
        CodeMySpec.Environments.clean_otp_env()

    Logger.info("[Spex] Running: #{command}")

    # The output is returned, not discarded. `{_raw_output, exit_code}` was the
    # whole of why a failing spex sweep could not be diagnosed: an empty JSONL
    # plus a nonzero exit becomes `{:spex_suite_did_not_run, code}`, and the
    # reason — a spex that would not compile, a crash before `:suite_finished`,
    # anything `mix spex` printed — existed nowhere afterwards. Not in
    # `harness.log`, which records only the command; not on the server; not in
    # the stop response.
    #
    # exunit already carries it: `{:test_suite_did_not_run, status, excerpt}`
    # (`runners.ex:214`). This is the same tuple one analyzer short.
    case Environments.cmd(environment, "mix", spex_args, stderr_to_stdout: true, env: cmd_env) do
      {raw_output, exit_code} ->
        result =
          parse_and_return_failures(
            temp_file,
            exit_code,
            environment,
            caller_provided_file,
            raw_output,
            project_root
          )

        unless caller_provided_file, do: cleanup_temp_file(temp_file, environment)
        result
    end
  rescue
    exception ->
      Logger.error("[Spex] Execution error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  @doc """
  Parses JSONL failure file into Failure structs.

  ## Parameters

  - `path` - Path to the JSONL file

  ## Returns

  `{:ok, [Failure.t()]}` - List of parsed failures (empty if file doesn't exist or is empty)
  `{:error, term()}` - If JSON parsing fails
  """
  # The JSONL is produced by `mix spex` running *inside* the environment, so it
  # is read back through the same environment. Reading it with File.read meant
  # the run wrote its results on one machine and the parser looked for them on
  # another — which surfaces as "0 failures", the same answer as a clean run.
  @spec parse_jsonl(String.t(), Environment.t() | nil) ::
          {:ok, [Failure.t()]} | {:error, term()}
  def parse_jsonl(path, env_or_nil \\ nil) do
    case read_jsonl(env_or_nil, path) do
      {:ok, ""} ->
        {:ok, []}

      {:ok, content} ->
        parse_jsonl_content(content)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A nil environment means the caller already holds the file on this machine —
  # the `:output_file` replay seam. `Environments.read_file(nil, _)` answers
  # `:no_environment`, so every replay failed to parse and the analyzer
  # contributed nothing, which reads as a clean run rather than as an error.
  defp read_jsonl(nil, path), do: File.read(path)
  defp read_jsonl(env, path), do: Environments.read_file(env, path)

  # Private functions

  # `mix spex` (sexy_spex) filters explicit args with File.exists?/1 only — a
  # directory passes that check, loads zero tests, and the run reports "clean"
  # with an empty JSONL no matter what the directory contains. Expand directory
  # args to their *_spex.exs files here so `mix spex test/spex/some_story/`
  # runs what the caller meant.
  @doc false
  def expand_directory_args(args, project_root, env_or_nil \\ nil) do
    env = env_or_nil || Environment.new(:local, project_root)

    Enum.flat_map(args, fn arg ->
      cond do
        String.starts_with?(arg, "-") ->
          [arg]

        directory?(env, Path.expand(arg, project_root)) ->
          env
          |> Environments.glob(Path.join(Path.expand(arg, project_root), "**/*_spex.exs"))
          |> Enum.map(&Path.relative_to(&1, project_root))
          |> spex_files_or_arg(arg)

        true ->
          [arg]
      end
    end)
  end

  # `Environments` exposes no dir? predicate; a successful listing is the check.
  # A directory with no spex in it is passed through untouched rather than
  # expanded to nothing — `mix spex <dir>` can then say so itself.
  defp spex_files_or_arg([], arg) do
    Logger.warning("[Spex] Directory arg #{arg} contains no *_spex.exs files")
    [arg]
  end

  defp spex_files_or_arg(files, _arg), do: files

  defp directory?(env, path), do: match?({:ok, _}, Environments.list_directory(env, path))

  defp build_args(args, temp_file, quiet) do
    base_args = ["spex" | args] ++ ["--jsonl=#{temp_file}"]

    if quiet do
      base_args ++ ["--quiet"]
    else
      base_args
    end
  end

  # `nil` env means "read on this machine": the caller-provided path is the
  # cassette seam, a fixture on the harness's own disk rather than something
  # `mix spex` wrote inside the environment.
  defp parse_and_return_failures(
         temp_file,
         exit_code,
         env,
         caller_provided_file,
         raw_output,
         project_root
       ) do
    case parse_jsonl(temp_file, if(caller_provided_file, do: nil, else: env)) do
      {:ok, failures} ->
        {:ok, Enum.map(failures, &relativize_error_file(&1, project_root)), exit_code, raw_output}

      {:error, reason} ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end

  # `error.file` is the one path in a failure that can arrive absolute, and it
  # has to leave here relative to the working copy root.
  #
  # `Runners.spex_location/1` normally takes the file from a stacktrace frame,
  # which is already relative. Its fallback — a failure with no `_spex.exs`
  # frame at all, which is what `** (EXIT from #PID<…>) an exception was raised`
  # produces when a linked LiveView dies — reads `error.file` instead, and that
  # is absolute.
  #
  # An absolute path is not merely inconsistent. `clear_problems_for_missing_files/2`
  # deletes every Problem whose path is not in the current file list, and that
  # list is relative, so such a row is removed on the next sync as though its
  # file had been deleted. The failure disappears without being fixed and
  # returns on the next sweep — four of them observed doing exactly that
  # (`cc643bf3`). It also costs the component link and session attribution,
  # which both join on relative paths.
  #
  # Here rather than server-side: `Runners.from_raw/2` converts where there is
  # no working copy and no cwd to relativize against, which is how this went
  # unnoticed.
  @doc false
  # Public only so the rule can be asserted without a live `mix spex` — the same
  # reason `Runners.spex_location/1` is, and for the same kind of rule.
  def relativize_error_file(failure, project_root)

  def relativize_error_file(%Failure{} = failure, project_root) do
    failure
    |> relativize_error(project_root)
    |> relativize_spec_file(project_root)
  end

  def relativize_error_file(failure, _project_root), do: failure

  defp relativize_error(%Failure{error: %Error{file: file} = error} = failure, project_root)
       when is_binary(file) do
    %{failure | error: %{error | file: Path.relative_to(file, project_root)}}
  end

  defp relativize_error(failure, _project_root), do: failure

  # `spec_file` arrives absolute for the same reason `error.file` does on the
  # backstop path: both come from `test.tags[:file]`, and ExUnit records that
  # absolute. Relativized here rather than in the fork, so the fork emits one
  # unambiguous thing and this side owns what the working copy's paths look
  # like.
  defp relativize_spec_file(%Failure{spec_file: file} = failure, project_root)
       when is_binary(file) do
    %{failure | spec_file: Path.relative_to(file, project_root)}
  end

  defp relativize_spec_file(failure, _project_root), do: failure

  defp cleanup_temp_file(temp_file, env) do
    Environments.delete_file(env, temp_file)
  end

  defp parse_jsonl_content(content) do
    lines =
      content
      |> String.split("\n", trim: true)
      |> Enum.reject(&(&1 == ""))

    parse_lines(lines, [])
  end

  defp parse_lines([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_lines([line | rest], acc) do
    case Jason.decode(line) do
      {:ok, data} ->
        failure = build_failure(data)
        parse_lines(rest, [failure | acc])

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp build_failure(data) do
    %Failure{
      spex: data["spex"],
      scenario: data["scenario"],
      # Absent until the formatter emits it (cd2a0db4). `nil` reads exactly as
      # it does today — the reader lands before the writer, which is the safe
      # order for a protocol change.
      spec_file: data["spec_file"],
      steps: build_steps(data["steps"] || []),
      error: build_error(data["error"])
    }
  end

  defp build_steps(steps_data) do
    Enum.map(steps_data, fn step ->
      %Step{
        type: step["type"],
        description: step["description"],
        status: step["status"]
      }
    end)
  end

  defp build_error(nil), do: nil

  defp build_error(error_data) do
    %Error{
      message: error_data["message"],
      file: error_data["file"],
      line: error_data["line"],
      stacktrace: error_data["stacktrace"] || [],
      left: error_data["left"],
      right: error_data["right"]
    }
  end
end
