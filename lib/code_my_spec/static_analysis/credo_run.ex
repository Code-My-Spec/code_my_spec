defmodule CodeMySpec.StaticAnalysis.CredoRun do
  @moduledoc """
  The device half of the Credo analyzer: run `mix credo` and hand back the
  issues it printed.

  Builds no `%Problem{}` (that needs the database): returns `issues` exactly as
  Credo emitted them, string-keyed, which `ProblemConverter.from_credo/1` accepts
  on the server.

  ## Unreadable output is an error, not a clean sweep

  Output this cannot parse returns an error rather than `{:ok, []}`, which over
  a wire is recorded as a clean sweep (and a `:full` reconcile of `[]` deletes
  every credo Problem). `Analyzers.Credo` and `Analyzers.Sobelow` refuse the
  same way; keep the three in line.
  """

  require Logger

  alias CodeMySpec.ExecutionContexts

  @doc """
  Run Credo in `environment` and return its issues.

  ## Options

  - `:files` — restrict the sweep to these paths (relative to the project root)
  - `:config_file` — passed through as `--config-file`

  Returns `{:ok, [issue_map], raw_output}` or `{:error, reason}`. An empty
  list means Credo ran and found nothing; a failure to run is an error, never
  an empty list — those two must not arrive at the server as the same answer.

  `raw_output` is what Credo actually printed — JSON, per `@output_args`, so
  it is not what a human running `mix credo` themselves would see, but it is
  the real tool output rather than a count or a line reformatted from the
  parsed issues. See `.code_my_spec/rules/analysis_output_fidelity.md`.
  """
  @spec run(ExecutionContexts.ExecutionContext.t(), keyword()) ::
          {:ok, [map()], String.t()} | {:error, String.t()}
  def run(environment, opts \\ []) do
    if available?(environment) do
      execute(environment, opts)
    else
      {:error, "credo is not installed in this project (no deps/credo)"}
    end
  end

  @doc """
  Whether Credo can run against this working copy at all.

  Through `ExecutionContexts`, not `File`: on a remote environment the `mix` that
  would run is not on this machine's disk.
  """
  @spec available?(ExecutionContexts.ExecutionContext.t()) :: boolean()
  def available?(environment) do
    ExecutionContexts.exec_file_exists?(environment, "mix.exs") and
      ExecutionContexts.exec_file_exists?(environment, "deps/credo")
  end

  defp execute(environment, opts) do
    cwd = environment.cwd

    args = build_args(opts, cwd)

    # clean_otp_env keeps the child `mix`/`erl` off a Burrito release's
    # extracted ERTS (see CodeMySpec.ExecutionContexts.clean_otp_env/0).
    cmd_opts = [
      stderr_to_stdout: true,
      env: Keyword.get(opts, :extra_env, []) ++ ExecutionContexts.clean_otp_env()
    ]

    Logger.info("[CredoRun] Running: mix #{Enum.join(args, " ")}")

    # Compile first to keep ordinary compiler output separate. Credo's
    # loadpaths step can still compile a dependency, so parse its JSON below.
    case ExecutionContexts.cmd(environment, "mix", ["compile"], cmd_opts) do
      {_compile_output, 0} ->
        run_credo(environment, args, cmd_opts)

      {compile_output, status} ->
        {:error,
         "credo was not run: mix compile exited #{status}: #{String.trim(compile_output)}"}
    end
  rescue
    exception ->
      {:error, "credo crashed: #{Exception.message(exception)}"}
  end

  defp run_credo(environment, args, cmd_opts) do
    case ExecutionContexts.cmd(environment, "mix", args, cmd_opts) do
      # Credo ORs category bits into its exit status (warning is 16).
      # Its own command/configuration failures start at 128.
      {output, exit_code} when exit_code in 0..31 ->
        parse(output)

      {output, exit_code} ->
        {:error, "credo was not run: exited #{exit_code}: #{String.trim(output)}"}
    end
  rescue
    exception ->
      {:error, "credo crashed: #{Exception.message(exception)}"}
  end

  # Split so the reproduce hint cannot drift from what actually runs. The first
  # list decides *which findings exist*; the second only decides how they are
  # printed for a parser.
  @selection_args ["credo", "suggest", "--all", "--all-priorities"]
  @output_args ["--format", "json", "--no-color"]

  defp build_args(opts, cwd) do
    base = @selection_args ++ @output_args

    args =
      case Keyword.get(opts, :config_file) do
        nil -> base
        config_file -> base ++ ["--config-file", config_file]
      end

    case Keyword.get(opts, :files) do
      nil -> args
      [] -> args
      files when is_list(files) -> args ++ make_relative(files, cwd)
    end
  end

  defp make_relative(files, cwd) do
    abs_cwd = Path.expand(cwd)

    Enum.map(files, fn file ->
      abs_file = Path.expand(file)

      case Path.relative_to(abs_file, abs_cwd) do
        ^abs_file -> file
        relative -> relative
      end
    end)
  end

  @doc "Credo's issues out of everything it printed, or why they could not be read."
  @spec parse(String.t()) :: {:ok, list(), String.t()} | {:error, String.t()}
  def parse(output) do
    case extract_json(output) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        {:ok, issues, output}

      {:ok, _other} ->
        {:error, "unexpected JSON structure from credo"}

      :error ->
        unreadable(output)
    end
  end

  # A stale `deps/` is not a JSON problem; it is the one refusal with a known
  # remedy, so say that instead.
  defp unreadable(output) do
    if CodeMySpec.Compile.unsatisfied_deps?(output) do
      {:error,
       "deps out of date with mix.lock; run `mix deps.get` in this working copy. " <>
         (output |> String.trim() |> String.slice(0, 300))}
    else
      unreadable_json(output)
    end
  end

  # The excerpt is carried because the reason is usually in it (a missing
  # credo task, a compile error).
  defp unreadable_json(output) do
    Logger.warning(
      "[CredoRun] no JSON document in credo's output: " <>
        (output |> String.trim() |> String.slice(0, 200))
    )

    {:error,
     "credo produced output that is not JSON: " <>
       (output |> String.trim() |> String.slice(0, 300))}
  end

  @doc "Decode the complete Credo JSON document after any compiler output."
  @spec extract_json(String.t()) :: {:ok, map()} | :error
  def extract_json(output) do
    output
    |> brace_offsets()
    |> Enum.find_value(:error, fn offset ->
      candidate = binary_part(output, offset, byte_size(output) - offset)

      case Jason.decode(String.trim(candidate)) do
        {:ok, %{"issues" => issues} = decoded} when is_list(issues) -> {:ok, decoded}
        _ -> nil
      end
    end)
  end

  @max_candidates 200

  defp brace_offsets(output) do
    output
    |> :binary.matches("{")
    |> Enum.take(@max_candidates)
    |> Enum.map(fn {offset, _length} -> offset end)
  end
end
