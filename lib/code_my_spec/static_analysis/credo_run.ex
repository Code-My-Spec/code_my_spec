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

  alias CodeMySpec.Environments

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
  @spec run(Environments.Environment.t(), keyword()) ::
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

  Through `Environments`, not `File`: on a remote environment the `mix` that
  would run is not on this machine's disk.
  """
  @spec available?(Environments.Environment.t()) :: boolean()
  def available?(environment) do
    Environments.exec_file_exists?(environment, "mix.exs") and
      Environments.exec_file_exists?(environment, "deps/credo")
  end

  defp execute(environment, opts) do
    cwd = environment.cwd

    args = build_args(opts, cwd)

    # clean_otp_env keeps the child `mix`/`erl` off a Burrito release's
    # extracted ERTS (see CodeMySpec.Environments.clean_otp_env/0).
    cmd_opts = [
      stderr_to_stdout: true,
      env: Keyword.get(opts, :extra_env, []) ++ Environments.clean_otp_env()
    ]

    Logger.info("[CredoRun] Running: mix #{Enum.join(args, " ")}")

    case Environments.cmd(environment, "mix", args, cmd_opts) do
      {output, exit_code} when exit_code in 0..1 ->
        parse(output)

      # Credo exits >1 for its own failures. Output is still worth parsing when
      # there is any — but no output at all means it never ran, and that is an
      # error rather than a clean sweep.
      {output, exit_code} ->
        if String.trim(output) == "" do
          {:error, "credo exited #{exit_code} with no output"}
        else
          parse(output)
        end
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

      {:ok, %{}} ->
        {:ok, [], output}

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

  @doc """
  The JSON document credo printed, out of everything else it printed.

  Compilation chatter precedes it and quotes Elixir source full of braces, so
  neither the first nor the last `{` is reliable. Tries each `{` in order and
  keeps the first that decodes to a whole document with an `issues` key (the
  key stops a stray `{}` in a warning passing for a clean run).
  """
  @spec extract_json(String.t()) :: {:ok, map()} | :error
  def extract_json(output) do
    output
    |> brace_offsets()
    |> Enum.find_value(:error, fn offset ->
      candidate = binary_part(output, offset, byte_size(output) - offset)

      case Jason.decode(String.trim(candidate)) do
        {:ok, %{"issues" => _} = decoded} -> {:ok, decoded}
        _ -> nil
      end
    end)
  end

  # Bounded so all-braces, no-JSON output cannot make a failed run a long one.
  @max_candidates 200

  defp brace_offsets(output) do
    case :binary.matches(output, "{") do
      [] -> []
      matches -> matches |> Enum.take(@max_candidates) |> Enum.map(fn {start, _} -> start end)
    end
  end
end
