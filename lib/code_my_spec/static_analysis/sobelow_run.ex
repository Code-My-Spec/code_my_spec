defmodule CodeMySpec.StaticAnalysis.SobelowRun do
  @moduledoc """
  The device half of the Sobelow analyzer: run `mix sobelow` and hand back the
  findings it printed.

  Derived from `CodeMySpec.StaticAnalysis.Analyzers.Sobelow` on the server,
  which cannot be copied verbatim — its `run/2` finishes by building
  `%Problems.Problem{}` structs against a `%Users.Scope{}`, and both of those
  are database. What is left once those go is this: build the args, shell out
  through `Environments`, find the JSON in the output, and return `findings`
  exactly as Sobelow emitted them.

  Conversion to Problems stays on the server, where the schema is. See
  `CodeMySpec.StaticAnalysis.CredoRun`, which this mirrors — same shape, same
  reasoning, `9a78afa1`.

  ## Unreadable output is an error, not a clean sweep

  Output this cannot parse returns an error rather than `{:ok, []}`, for the
  same reason `CredoRun` gives at length: over a wire, an empty list and a
  failed run are indistinguishable, and a `:full` reconcile against an empty
  list deletes every Problem the source has.
  """

  require Logger

  alias CodeMySpec.Environments

  @doc """
  Run Sobelow in `environment` and return its findings.

  Returns `{:ok, [finding_map], raw_output}` or `{:error, reason}`. An empty
  list means Sobelow ran and found nothing; a failure to run is an error,
  never an empty list.

  `raw_output` is what Sobelow actually printed — JSON, per `--format json` —
  not a count or a line reformatted from the parsed findings. See
  `.code_my_spec/rules/analysis_output_fidelity.md`.
  """
  @spec run(Environments.Environment.t(), keyword()) ::
          {:ok, [map()], String.t()} | {:error, String.t()}
  def run(environment, opts \\ []) do
    if available?(environment) do
      execute(environment, opts)
    else
      {:error, "sobelow is not installed in this project (no deps/sobelow)"}
    end
  end

  @doc """
  Whether Sobelow can run against this working copy at all.

  Through `Environments`, not `File` — see `CredoRun.available?/1`'s doc for
  why: the question is about the `mix` that would actually run, which on a
  remote environment is not this machine's disk.
  """
  @spec available?(Environments.Environment.t()) :: boolean()
  def available?(environment) do
    Environments.exec_file_exists?(environment, "mix.exs") and
      Environments.exec_file_exists?(environment, "deps/sobelow")
  end

  @args ["sobelow", "--format", "json", "--private"]

  defp execute(environment, opts) do
    cmd_opts = [
      stderr_to_stdout: true,
      env: Keyword.get(opts, :extra_env, []) ++ Environments.clean_otp_env()
    ]

    Logger.info("[SobelowRun] Running: mix #{Enum.join(@args, " ")}")

    case Environments.cmd(environment, "mix", @args, cmd_opts) do
      # Sobelow exit codes: 0 = no findings, 1 = findings found. Exit 1 with no
      # output is not "findings found" — see the moduledoc on unreadable
      # output.
      {output, exit_code} when exit_code in 0..1 ->
        parse(output)

      {output, exit_code} ->
        if String.trim(output) == "" do
          {:error, "sobelow exited #{exit_code} with no output"}
        else
          parse(output)
        end
    end
  rescue
    exception ->
      {:error, "sobelow crashed: #{Exception.message(exception)}"}
  end

  defp parse(output) do
    output = String.trim(output)

    if output == "" do
      {:error, "sobelow produced no output; it likely never ran"}
    else
      case extract_json(output) do
        {:ok, %{"findings" => findings}} when is_map(findings) ->
          all =
            Map.get(findings, "high_confidence", []) ++
              Map.get(findings, "medium_confidence", []) ++
              Map.get(findings, "low_confidence", [])

          {:ok, all, output}

        {:ok, %{"findings" => findings}} when is_list(findings) ->
          {:ok, findings, output}

        {:ok, %{}} ->
          {:ok, [], output}

        {:ok, _other} ->
          {:error, "unexpected JSON structure from sobelow"}

        :error ->
          Logger.warning(
            "[SobelowRun] no JSON document in sobelow's output: " <>
              String.slice(output, 0, 200)
          )

          {:error, "sobelow produced output that is not JSON: " <> String.slice(output, 0, 300)}
      end
    end
  end

  @doc """
  The JSON document sobelow printed, out of everything else it printed.

  Same reasoning as `CredoRun.extract_json/1`: compilation chatter can precede
  the real document and can itself contain braces, so this tries each `{` in
  order and keeps the first that yields a whole document with a `findings`
  key, rather than assuming the first or last brace in the output starts it.
  """
  @spec extract_json(String.t()) :: {:ok, map()} | :error
  def extract_json(output) do
    output
    |> brace_offsets()
    |> Enum.find_value(:error, fn offset ->
      candidate = binary_part(output, offset, byte_size(output) - offset)

      case Jason.decode(String.trim(candidate)) do
        {:ok, %{"findings" => _} = decoded} -> {:ok, decoded}
        _ -> nil
      end
    end)
  end

  @max_candidates 200

  defp brace_offsets(output) do
    case :binary.matches(output, "{") do
      [] -> []
      matches -> matches |> Enum.take(@max_candidates) |> Enum.map(fn {start, _} -> start end)
    end
  end
end
