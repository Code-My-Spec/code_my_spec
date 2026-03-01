defmodule CodeMySpec.AgentTasks.FixIssues do
  @moduledoc """
  Agent task for fixing accepted QA issues.

  Reads accepted issues from `.code_my_spec/issues/accepted/`, filters to those
  at or above the specified severity that lack a `## Resolution` section, and
  builds a prompt instructing the agent to fix each issue and document the resolution.

  Accepts an optional minimum severity argument (default: "medium") from
  `session.state["topic"]`.

  Two main functions:
  - `command/3` — Reads accepted issues, builds fix prompt
  - `evaluate/3` — Checks that all medium+ accepted issues have resolution sections
  """

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.{Environments, Paths}

  @severity_order ~w(critical high medium low info)
  @blocking_severities ~w(critical high medium)

  @doc """
  Read accepted issues without resolutions and build a fix prompt.

  Globs `accepted/`, filters to issues at or above the minimum severity that
  lack a `## Resolution` section, and builds a prompt with fix instructions.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, session, _opts \\ []) do
    min_severity = get_min_severity(session)
    env = scope.environment

    files = Environments.glob(env, "#{Paths.issues_accepted_dir()}/*.md") || []

    unresolved =
      files
      |> Enum.map(fn path ->
        case Environments.read_file(env, path) do
          {:ok, content} -> {path, content}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn {_path, content} ->
        severity = parse_severity(content)
        has_resolution = has_resolution?(content)
        at_or_above_severity?(severity, min_severity) and not has_resolution
      end)

    prompt = build_prompt(unresolved, min_severity)
    {:ok, TaskMarker.build("FixIssues", min_severity) <> "\n\n" <> prompt}
  end

  @doc """
  Check that all medium+ accepted issues have resolution sections.

  Uses `@blocking_severities` (critical, high, medium) regardless of the
  session's min_severity argument — the gate is always medium+.

  Returns:
  - `{:ok, :valid}` when no blocking unresolved issues remain
  - `{:ok, :invalid, feedback}` when unresolved blocking issues exist
  """
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment

    files = Environments.glob(env, "#{Paths.issues_accepted_dir()}/*.md") || []

    blocking =
      files
      |> Enum.filter(fn path ->
        case Environments.read_file(env, path) do
          {:ok, content} ->
            severity = parse_severity(content)
            severity in @blocking_severities and not has_resolution?(content)

          _ ->
            false
        end
      end)

    case blocking do
      [] ->
        {:ok, :valid}

      files ->
        names = Enum.map_join(files, "\n", &"- `#{Path.basename(&1)}`")

        {:ok, :invalid,
         "#{length(files)} unresolved medium+ issue(s) in accepted/:\n\n#{names}\n\nFix each issue and add a ## Resolution section describing what was done."}
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt([], min_severity) do
    """
    # Fix Issues

    No unresolved accepted issues found at #{min_severity}+ severity. Nothing to fix.
    """
  end

  defp build_prompt(unresolved, min_severity) do
    issues_text =
      unresolved
      |> Enum.sort_by(fn {_path, content} -> severity_index(parse_severity(content)) end)
      |> Enum.map_join("\n\n", fn {path, content} ->
        source_ref = extract_source(content)

        """
        ### `#{Path.basename(path)}`

        #{if source_ref, do: "**Source:** #{source_ref}\n", else: ""}
        ```markdown
        #{content}
        ```
        """
      end)

    """
    # Fix Issues

    You are fixing accepted QA issues at **#{min_severity}+** severity.

    ## Goal

    For each issue below:

    1. **Understand the problem** — read the issue description and source QA result
    2. **Fix the code** — use subagents (Agent tool) for the actual fix work. Group related issues
       into one subagent if they share a root cause. Each subagent should:
       - Read the relevant source files
       - Make the fix
       - Verify the fix works
    3. **Add a `## Resolution` section** to each issue file describing what was done:
       - Summary of the fix
       - Files changed
       - How the fix was verified
    4. **Run tests** after all fixes to verify nothing is broken: `mix test`

    ## QA Results

    Issue source references point to QA result files in `#{Paths.qa_dir()}/`. Read those
    files for additional context, reproduction steps, and screenshots.

    ## Unresolved Issues

    #{issues_text}

    ## Directory

    Accepted issues: `#{Paths.issues_accepted_dir()}/`

    Fix the issues, add resolution sections, and run tests to verify.
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_min_severity(%{state: %{"topic" => topic}}) when is_binary(topic) and topic != "" do
    severity = String.downcase(String.trim(topic))
    if severity in @severity_order, do: severity, else: "medium"
  end

  defp get_min_severity(_session), do: "medium"

  defp parse_severity(content) do
    case Regex.run(~r/^## Severity\s*\n\s*(\w+)/m, content) do
      [_, sev] -> String.downcase(sev)
      _ -> "unknown"
    end
  end

  defp has_resolution?(content) do
    Regex.match?(~r/^## Resolution/m, content)
  end

  defp extract_source(content) do
    case Regex.run(~r/^## Source\s*\n\s*(.+)/m, content) do
      [_, source] -> String.trim(source)
      _ -> nil
    end
  end

  defp severity_index(severity) do
    case Enum.find_index(@severity_order, &(&1 == severity)) do
      nil -> 999
      idx -> idx
    end
  end

  defp at_or_above_severity?(severity, min_severity) do
    severity_index(severity) <= severity_index(min_severity)
  end
end
