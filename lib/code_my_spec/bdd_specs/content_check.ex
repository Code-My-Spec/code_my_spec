defmodule CodeMySpec.BddSpecs.ContentCheck do
  @moduledoc """
  Whether a spex file's *text* is a usable spec — parses, has scenarios with
  steps, and uses the project's Spex case template.

  Pure: content in, verdict out. Nothing here touches a filesystem, which is the
  point. The checks used to live inside `AgentTasks.WriteBddSpecs`, where they
  were reachable only by something holding an `Environment` — so on a light
  harness, where the server has no working copy, every one of them answered
  "file not found" for files that were sitting on the agent's disk. Six of them,
  in a stop the agent could not clear by any edit, while the requirement graph
  read the harness's file report and correctly reported the same specs present.

  With the checks separated from the reading, the harness's scanner can run them
  where the disk is and send only the verdict — the same split `:spec` and
  `:review` files already use, and the reason `Files.Scanner` can work without a
  database.
  """

  alias CodeMySpec.BddSpecs.Parser

  @type reason ::
          :no_scenarios
          | :missing_steps
          | :missing_spex_case
          | {:syntax_error, %{optional(:line) => integer() | nil, message: String.t()}}
          | {:parse_error, term()}

  @doc """
  Check spec text. `:ok`, or `{:error, reason}` naming the first thing wrong.

  `path` is used only for compiler messages, so it can be any label — nothing
  reads it back off a disk.
  """
  @spec check(String.t(), String.t()) :: :ok | {:error, reason()}
  def check(content, path) when is_binary(content) do
    with :ok <- compiles(content, path),
         {:ok, spec} <- parsed(content, path),
         :ok <- uses_spex_case(content) do
      has_scenarios_with_steps(spec)
    end
  end

  @doc """
  One line of English for a reason, for an agent to act on.

  `path` appears only where it helps locate the problem.
  """
  @spec describe(reason() | term(), String.t()) :: String.t()
  def describe(:file_not_found, _path), do: "Spec file not found"

  # Deliberately not "not found". The server has no working copy, so it did not
  # look — and reporting that as absence is what made this unresolvable from the
  # agent's side: the file it was told to write was already there.
  def describe(:no_environment, _path) do
    "Spec content could not be read here — this server holds no working copy, " <>
      "and the harness has not reported a verdict for this file yet. " <>
      "This is not a claim that the file is missing."
  end

  # Present in the harness's report, with no verdict attached — an older scanner
  # that does not check spex content. Existence is all that is known, and saying
  # more than that in either direction is what this whole module exists to stop.
  def describe(:no_verdict, _path) do
    "This spec exists in the harness's file report, but that harness sent no " <>
      "validation verdict for it — so its contents have not been checked here. " <>
      "Upgrade the harness to have spex files validated where the disk is."
  end

  def describe(:no_scenarios, _path), do: "Must contain at least one scenario"

  def describe(:missing_steps, _path), do: "All scenarios must have Given/When/Then steps"

  def describe(:missing_spex_case, _path) do
    "Spec must `use <App>Spex.Case` as the base case template " <>
      "(provides SexySpex DSL + Phoenix.ConnTest + Phoenix.LiveViewTest + DB sandbox). " <>
      "Do not `use <App>Web.ConnCase` directly from a spec."
  end

  def describe({:syntax_error, %{line: line, message: msg}}, path) when is_integer(line),
    do: "Compilation failed:\n  #{path}:#{line}: #{msg}"

  def describe({:syntax_error, %{message: msg}}, path),
    do: "Compilation failed:\n  #{path}: #{msg}"

  def describe({:parse_error, reason}, _path), do: "Parse error: #{inspect(reason)}"

  def describe(other, _path), do: inspect(other)

  defp compiles(content, path) do
    case Code.string_to_quoted(content, file: path) do
      {:ok, _ast} ->
        :ok

      {:error, {meta, msg, token}} ->
        {:error, {:syntax_error, %{line: line_from(meta), message: message_from(msg, token)}}}
    end
  end

  defp parsed(content, path) do
    case Parser.parse(content, path) do
      {:ok, spec} -> {:ok, spec}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  defp line_from(meta) when is_list(meta), do: Keyword.get(meta, :line)
  defp line_from(line) when is_integer(line), do: line
  defp line_from(_), do: nil

  defp message_from({header, body}, token) when is_binary(header) and is_binary(body),
    do: "#{header}#{body}#{token}"

  defp message_from(msg, token) when is_binary(msg), do: "#{msg}#{token}"
  defp message_from(msg, _token), do: inspect(msg)

  # The `spex/scenario/given_/when_/then_` macros only resolve when the file
  # uses the project's case template, so a spec without it cannot run at all.
  #
  # Unparseable content returns `:ok` here rather than a second complaint —
  # `compiles/2` has already said what is wrong, and two messages about one
  # broken file read as two problems.
  defp uses_spex_case(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} -> if uses_spex_case?(ast), do: :ok, else: {:error, :missing_spex_case}
      {:error, _} -> :ok
    end
  end

  defp uses_spex_case?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:use, _, [{:__aliases__, _, parts} | _]} -> spex_case_alias?(parts)
      _ -> false
    end)
  end

  defp spex_case_alias?(parts) when is_list(parts) and length(parts) >= 2 do
    parts
    |> Enum.map_join(".", &Atom.to_string/1)
    |> String.match?(~r/Spex\.Case$/)
  end

  defp spex_case_alias?(_), do: false

  defp has_scenarios_with_steps(spec) do
    cond do
      Enum.empty?(spec.scenarios) -> {:error, :no_scenarios}
      not Enum.all?(spec.scenarios, &has_steps?/1) -> {:error, :missing_steps}
      true -> :ok
    end
  end

  defp has_steps?(scenario) do
    not Enum.empty?(scenario.given_steps) or
      not Enum.empty?(scenario.when_steps) or
      not Enum.empty?(scenario.then_steps)
  end
end
