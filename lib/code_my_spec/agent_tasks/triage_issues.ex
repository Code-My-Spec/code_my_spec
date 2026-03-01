defmodule CodeMySpec.AgentTasks.TriageIssues do
  @moduledoc """
  Agent task for triaging incoming QA issues.

  Reviews all issues in `.code_my_spec/issues/incoming/`, decides dispositions
  (accept, dismiss, merge), and moves files to `accepted/` or `dismissed/`.

  Accepts an optional minimum severity argument (default: "medium") from
  `session.state["topic"]`. Only issues at or above the specified severity
  are included in the triage.

  Two main functions:
  - `command/3` — Reads incoming issues, builds triage prompt
  - `evaluate/3` — Checks that no incoming issues at or above min severity remain
  """

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.{Environments, Paths}

  @severity_order ~w(critical high medium low info)

  @doc """
  Read incoming issues and build a triage prompt.

  Globs `incoming/`, reads each issue at or above the minimum severity,
  and builds a prompt instructing the agent to review, deduplicate, and
  execute dispositions.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, session, _opts \\ []) do
    min_severity = get_min_severity(session)
    env = scope.environment

    files = Environments.glob(env, "#{Paths.issues_incoming_dir()}/*.md") || []

    issues =
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
        at_or_above_severity?(severity, min_severity)
      end)

    prompt = build_prompt(issues, min_severity)
    {:ok, TaskMarker.build("TriageIssues", min_severity) <> "\n\n" <> prompt}
  end

  @doc """
  Check that no incoming issues at or above the minimum severity remain.

  Returns:
  - `{:ok, :valid}` when incoming/ has no matching issues
  - `{:ok, :invalid, feedback}` when untriaged issues remain
  """
  def evaluate(scope, session, _opts \\ []) do
    min_severity = get_min_severity(session)
    env = scope.environment

    files = Environments.glob(env, "#{Paths.issues_incoming_dir()}/*.md") || []

    remaining =
      files
      |> Enum.filter(fn path ->
        case Environments.read_file(env, path) do
          {:ok, content} ->
            severity = parse_severity(content)
            at_or_above_severity?(severity, min_severity)

          _ ->
            false
        end
      end)

    case remaining do
      [] ->
        {:ok, :valid}

      files ->
        names = Enum.map_join(files, "\n", &"- `#{Path.basename(&1)}`")

        {:ok, :invalid,
         "#{length(files)} untriaged issue(s) remain in incoming/ at #{min_severity}+ severity:\n\n#{names}\n\nReview each issue and move to accepted/ or dismissed/."}
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt([], min_severity) do
    """
    # Triage Issues

    No incoming issues found at #{min_severity}+ severity. Nothing to triage.
    """
  end

  defp build_prompt(issues, min_severity) do
    grouped =
      issues
      |> Enum.group_by(fn {_path, content} -> parse_severity(content) end)
      |> Enum.sort_by(fn {sev, _} -> severity_index(sev) end)

    issues_text =
      Enum.map_join(grouped, "\n\n", fn {severity, group} ->
        items =
          Enum.map_join(group, "\n\n", fn {path, content} ->
            "### `#{Path.basename(path)}`\n\n```markdown\n#{content}\n```"
          end)

        "## #{String.capitalize(severity)} (#{length(group)})\n\n#{items}"
      end)

    """
    # Triage Issues

    You are triaging incoming QA issues at **#{min_severity}+** severity.

    ## Goal

    Produce a clean `accepted/` folder with real, deduplicated issues. Your job:

    1. **Read all incoming issues** listed below
    2. **Identify duplicates** — issues describing the same underlying problem
    3. **Decide a disposition** for each issue:
       - **Accept** — real issue, move to `#{Paths.issues_accepted_dir()}/`
       - **Dismiss** — not a real bug (test artifact, expected behavior, duplicate), move to `#{Paths.issues_dismissed_dir()}/`
       - **Merge** — consolidate evidence from duplicates into one accepted issue, dismiss the others
    4. **Execute** — move files using `Write` to the target directory and delete from `incoming/`

    When merging duplicates: pick the best title, consolidate description and evidence into
    one accepted issue file, and dismiss the rest with a note about which issue they merged into.

    Ensure the `accepted/` and `dismissed/` directories exist before writing (create them if needed).

    ## Incoming Issues

    #{issues_text}

    ## Directories

    - Incoming: `#{Paths.issues_incoming_dir()}/`
    - Accepted: `#{Paths.issues_accepted_dir()}/`
    - Dismissed: `#{Paths.issues_dismissed_dir()}/`

    Stop the session when all issues have been triaged.
    """
  end

  # ============================================================================
  # Severity Helpers
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
