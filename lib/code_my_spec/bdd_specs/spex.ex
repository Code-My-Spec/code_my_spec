defmodule CodeMySpec.BddSpecs.Spex do
  @moduledoc """
  Executes Spex BDD specifications via `mix spex` and returns structured results.
  Wraps command execution with JSONL output parsing, capturing scenario pass/fail
  status and step-level failure details.
  """

  require Logger

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext

  alias CodeMySpec.BddSpecs.Spex.{Error, Failure, Step}

  @doc """
  Execute mix spex synchronously and parse results.

  ## Parameters

  - `args` - List of arguments to pass to mix spex (e.g., ["test/spex/login_spex.ex"])
  - `opts` - Keyword list of options:
    - `:execution_context` - ExecutionContext to run specs in (required); commands run in its cwd
    - `:quiet` - Suppress console output (default: false)
    - `:jsonl_path` - Custom path for JSONL output file (defaults to temp file)
    - `:output_file` - An existing JSONL to parse instead of running anything
    - `:extra_env` - Extra environment for the child process

  ## Returns

  `{:ok, failures, exit_code, raw_output}` - Parsed failures, exit code, and
  everything `mix spex` printed. The output matters on the path where there are
  no failures *and* a nonzero exit: that combination means the suite did not
  run, and the output is the only account of why.
  `{:error, {:parse_error, reason}}` - If JSONL parsing fails

  ## Example

      {:ok, failures, exit_code, _output} =
        Spex.execute(["test/spex/login_spex.ex"], execution_context: env)

      exit_code  # => 0 for success, non-zero for failure
  """
  @spec execute(args :: [String.t()], opts :: keyword()) ::
          {:ok, [Failure.t()], integer(), String.t()}
          | {:error, {:parse_error, String.t()}}
  def execute(args, opts \\ []) do
    environment = Keyword.fetch!(opts, :execution_context)
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

  # `:output_file` is the test-only seam: the caller supplied the run's JSONL,
  # so nothing is shelled out and the exit status is derived from the parsed
  # failures (a recorded exit code would make a passing run unsimulatable).
  # Same shape as the Credo analyzer's.
  defp replay_only?(opts), do: Keyword.has_key?(opts, :output_file)

  # `nil` env on purpose: a caller-provided output file is a real path on
  # the host disk, not something inside the project's (possibly in-memory)
  # environment. Same choice `parse_and_return_failures/4` makes.
  defp replay(output_file, _environment) do
    case parse_jsonl(output_file, nil) do
      {:ok, failures} ->
        Logger.info("[Spex] Replaying #{length(failures)} failure(s) from #{output_file}")
        # Empty output: nothing was shelled out.
        {:ok, failures, if(failures == [], do: 0, else: 1), ""}

      {:error, reason} ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end

  defp shell_out(args, opts, environment, project_root, quiet, temp_file, caller_provided_file) do
    args = expand_directory_args(args, project_root, environment)
    spex_args = build_args(args, temp_file, quiet)
    program = program(environment, "spex")
    command = program <> " " <> Enum.join(spex_args, " ")

    # The scrub keeps the child `mix`/`erl` off our Burrito ERTS (see
    # CodeMySpec.ExecutionContexts.clean_otp_env/0), and `merge_clean_env/1` applies
    # it without overwriting anything chosen here.
    # `extra_env` is how the harness hands over `MIX_TEST_PARTITION`, a database
    # `TestDatabase.env/1` has already created and migrated; without it a run
    # fails on a missing database in a way that looks like failing specs.
    # `merge_clean_env/1`, never `++ clean_otp_env()`: duplicate `:env` entries
    # apply in order, and the scrub's MIX_ENV=nil would unset "test".
    # See knowledge/requirements_graph/checkers, "BDD specs".
    cmd_env =
      ExecutionContexts.merge_clean_env(
        env: [{"MIX_ENV", "test"}] ++ Keyword.get(opts, :extra_env, [])
      )[:env]

    Logger.info("[Spex] Running: #{command}")

    # The output is returned, not discarded: an empty JSONL with a nonzero exit
    # means the suite did not run, and the output is the only record of why (as
    # exunit's `{:test_suite_did_not_run, status, excerpt}`).
    case ExecutionContexts.cmd(environment, program, spex_args,
           stderr_to_stdout: true,
           env: cmd_env
         ) do
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
  # The JSONL is written inside the environment, so it is read back through it;
  # reading the wrong machine's disk reads as "0 failures", a clean run.
  @spec parse_jsonl(String.t(), ExecutionContext.t() | nil) ::
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

  # A nil environment means the file is on this machine (the replay seam);
  # `ExecutionContexts.read_file(nil, _)` would answer `:no_environment`.
  defp read_jsonl(nil, path), do: File.read(path)
  defp read_jsonl(env, path), do: ExecutionContexts.read_file(env, path)

  # Private functions

  # `mix spex` accepts a directory arg, loads zero tests from it, and reports
  # clean.
  @doc """
  Expands any directory args (that `mix spex` would otherwise silently pass
  through with zero tests loaded) into their `*_spex.exs` files.
  """
  def expand_directory_args(args, project_root, env_or_nil \\ nil) do
    env = env_or_nil || ExecutionContext.new(:local, project_root)

    Enum.flat_map(args, fn arg ->
      cond do
        String.starts_with?(arg, "-") ->
          [arg]

        directory?(env, Path.expand(arg, project_root)) ->
          env
          |> ExecutionContexts.glob(Path.join(Path.expand(arg, project_root), "**/*_spex.exs"))
          |> Enum.map(&Path.relative_to(&1, project_root))
          |> spex_files_or_arg(arg)

        true ->
          [arg]
      end
    end)
  end

  # `ExecutionContexts` exposes no dir? predicate; a successful listing is the check.
  # A directory with no spex in it is passed through untouched rather than
  # expanded to nothing — `mix spex <dir>` can then say so itself.
  defp spex_files_or_arg([], arg) do
    Logger.warning("[Spex] Directory arg #{arg} contains no *_spex.exs files")
    [arg]
  end

  defp spex_files_or_arg(files, _arg), do: files

  defp directory?(env, path), do: match?({:ok, _}, ExecutionContexts.list_directory(env, path))

  # The project's `spex` recipe when it declares one, so how the suite runs —
  # sharded, say — is the project's choice. The arguments are the same either
  # way: `just spex …` and `mix spex …` both begin with the recipe/task name.
  defp program(environment, recipe),
    do: if(ExecutionContexts.recipe?(environment, recipe), do: "just", else: "mix")

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

  # `error.file` and `spec_file` can arrive absolute (ExUnit records
  # `test.tags[:file]` absolute; `Runners.spex_location/1` falls back to it when
  # no `_spex.exs` frame exists) and must leave relative to the working copy:
  # problem cleanup, component links and attribution all join on relative
  # paths. Done here, the only side with a root to relativize against.
  # See knowledge/requirements_graph/checkers, "BDD specs".
  @doc """
  Public only so the rule can be asserted without a live `mix spex` — the same
  reason `Runners.spex_location/1` is, and for the same kind of rule.
  """
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

  # Relativized here rather than in the formatter, so this side owns what the
  # working copy's paths look like.
  defp relativize_spec_file(%Failure{spec_file: file} = failure, project_root)
       when is_binary(file) do
    %{failure | spec_file: Path.relative_to(file, project_root)}
  end

  defp relativize_spec_file(failure, _project_root), do: failure

  defp cleanup_temp_file(temp_file, env) do
    ExecutionContexts.delete_file(env, temp_file)
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
      # `nil` when the formatter does not emit it.
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
