defmodule CodeMySpec.McpServers.Stories.Tools.TriageIssues do
  @moduledoc """
  Starts a triage session for incoming external issues.

  Fetches incoming issues and story titles, then returns a structured
  prompt guiding through triage decisions:
  - Obvious bug → accept the issue
  - Requires story change → update/create story, accept with story_id
  - Not valid → dismiss with reason
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :min_severity, :string, doc: "Minimum severity to triage: critical, high, medium (default), low, info"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         {:ok, min_severity} <- parse_severity(params[:min_severity] || "medium") do
      incoming = list_incoming_at_severity(scope, min_severity)
      stories = Stories.list_stories(scope)
      prompt = build_prompt(incoming, stories, min_severity)

      {:reply, Response.text(Response.tool(), prompt), frame}
    else
      {:error, {:invalid_severity, value}} ->
        {:reply,
         Response.error(
           Response.tool(),
           "Invalid min_severity #{inspect(value)}. Allowed: critical, high, medium, low, info."
         ), frame}

      {:error, reason} ->
        {:reply, Response.text(Response.tool(), "Error: #{inspect(reason)}"), frame}
    end
  end

  defp build_prompt([], _stories, min_severity) do
    "No incoming issues found at #{min_severity}+ severity. Nothing to triage."
  end

  defp build_prompt(issues, stories, min_severity) do
    issues_text = format_issues(issues)
    stories_text = format_stories(stories)

    """
    # Triage External Issues

    You are triaging **#{length(issues)}** incoming issue(s) at **#{min_severity}+** severity.
    These issues were reported by users via the feedback widget — they are external reports, not QA findings.

    ## Available Tools

    **Issue tools:**
    - `accept_issue` — accept a real issue (pass optional `story_id` to link it to a story)
    - `dismiss_issue` — dismiss with a reason (duplicate, not a bug, etc.)
    - `get_issue` — read full issue details
    - `list_issues` — list issues with filters

    **Story tools:**
    - `list_story_titles` — quick overview of all stories
    - `get_story` — read full story details
    - `update_story` — update an existing story's description or criteria
    - `create_story` — create a new story if the issue reveals missing functionality
    - `add_criterion` — add acceptance criteria to a story

    ## Triage Process

    For each incoming issue:

    1. **Read the issue** using `get_issue` to understand the full report
    2. **Check existing stories** — does this issue relate to an existing story?
    3. **Decide the disposition:**

       **a) Obvious bug, no story change needed**
       The issue describes a clear defect in existing functionality.
       → `accept_issue` with the issue ID

       **b) Requires story/requirements change**
       The issue reveals missing functionality or changed requirements.
       → Update the relevant story with `update_story` or create a new one with `create_story`
       → Then `accept_issue` with both the issue ID and the `story_id`

       **c) Not valid**
       Expected behavior, duplicate, or not actionable.
       → `dismiss_issue` with a clear reason

    ## Incoming Issues

    #{issues_text}

    ## Current Stories

    #{stories_text}

    Triage all issues before stopping.
    """
  end

  defp format_issues(issues) do
    issues
    |> Enum.group_by(& &1.severity)
    |> Enum.sort_by(fn {sev, _} -> Issue.severity_index(sev) end)
    |> Enum.map_join("\n\n", fn {severity, group} ->
      items =
        Enum.map_join(group, "\n", fn issue ->
          source = if issue.source, do: " [#{issue.source}]", else: ""
          "- `#{issue.id}` — #{issue.title} (#{issue.severity})#{source}"
        end)

      "### #{String.capitalize(to_string(severity))} (#{length(group)})\n\n#{items}"
    end)
  end

  defp format_stories([]) do
    "_No stories found for this project._"
  end

  defp format_stories(stories) do
    stories
    |> Enum.map_join("\n", fn story ->
      status = if story.status, do: " [#{story.status}]", else: ""
      "- `#{story.id}` — #{story.title}#{status}"
    end)
  end

  defp list_incoming_at_severity(scope, min_severity) do
    Issues.list_by_status(scope, :incoming)
    |> Enum.filter(fn issue ->
      Issue.severity_index(issue.severity) <= Issue.severity_index(min_severity)
    end)
  end

  defp parse_severity(s) when is_binary(s) do
    case String.downcase(String.trim(s)) do
      "critical" -> {:ok, :critical}
      "high" -> {:ok, :high}
      "medium" -> {:ok, :medium}
      "low" -> {:ok, :low}
      "info" -> {:ok, :info}
      _ -> {:error, {:invalid_severity, s}}
    end
  end
end
