defmodule CodeMySpec.Qa.Tools.ListQaAttempts do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Qa
  alias CodeMySpec.Stories

  @impl true
  def name, do: "list_qa_attempts"

  @impl true
  def description do
    """
    List the QA attempt history for a story.

    Returns every attempt on the story, most-recent first. Each entry
    carries the audit-grade fields: status, agent_id, scenarios (with
    observations), linked issue_ids, parent_attempt_id (the chain
    back), submitted_at, and any invalidation event with its reason
    and the engineer who issued it.

    Use this to:

    - Review prior QA on a story before redoing it
    - Audit who invalidated a pass and why
    - Walk the chain of attempts after one or more invalidations
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number whose QA history you want to read"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- fetch_story(scope, params.story_number) do
      attempts = Qa.list_qa_attempts(scope, story.id)
      attempts_response(story, attempts)
    else
      {:error, reason} ->
        error_response(reason)
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- fetch_story(scope, params.story_number) do
      {:ok, Enum.map(Qa.list_qa_attempts(scope, story.id), &script_row(&1, story))}
    end
  end

  defp script_row(a, story) do
    %{
      "id" => a.id,
      "status" => to_string(a.status),
      "agent_id" => a.agent_id,
      "submitted_at" => a.submitted_at && DateTime.to_iso8601(a.submitted_at),
      "parent_attempt_id" => a.parent_attempt_id,
      "stale" => a.stale,
      "stale_because" => stale_reason(a, story),
      "issue_ids" => a.issue_ids || [],
      "scenarios" =>
        Enum.map(a.scenarios, fn s ->
          %{
            "name" => s.name,
            "status" => to_string(s.status),
            "observation" => s.observation,
            "blocker_issue_id" => s.blocker_issue_id
          }
        end)
    }
  end

  defp fetch_story(scope, number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, "Story #{number} not found in this project."}
      story -> {:ok, story}
    end
  end

  defp attempts_response(story, []) do
    {:ok, "No QA attempts recorded for story #{story.number}."}
  end

  defp attempts_response(story, attempts) do
    body = Enum.map_join(attempts, "\n\n---\n\n", &render_attempt(&1, story))
    story_number = story.number

    {:ok,
     """
     QA history for story #{story_number} (#{length(attempts)} attempt#{if length(attempts) == 1, do: "", else: "s"}, most-recent first):

     #{body}
     """}
  end

  defp render_attempt(attempt, story) do
    invalidation = render_invalidation(attempt)

    """
    attempt_id: #{attempt.id}
    status:     #{attempt.status}
    agent_id:   #{attempt.agent_id || "(unknown)"}
    submitted_at: #{attempt.submitted_at}
    parent_attempt_id: #{attempt.parent_attempt_id || "none"}
    stale: #{attempt.stale}#{render_stale_reason(attempt, story)}
    #{render_review(attempt)}
    scenarios (#{length(attempt.scenarios)}):
    #{render_scenarios(attempt.scenarios)}
    issue_ids: #{render_issue_ids(attempt.issue_ids)}
    tools_used: #{render_tools_used(attempt.tools_used)}#{invalidation}
    """
    |> String.trim_trailing()
  end

  defp render_stale_reason(attempt, story) do
    case stale_reason(attempt, story) do
      nil -> ""
      reason -> "\nstale_because: #{reason}"
    end
  end

  @doc """
  Why `attempt` is stale, or nil when it is not.

  Staleness is decided when the attempt is submitted, against the story's own
  certification at that moment (`Qa.StoryReviews`): never against main, and not
  against the copy's HEAD. A pass is stale when what it reviewed was not what the
  story was then certified at — it reviewed commit R (stamped when QA started,
  because a pass takes an hour) and the story had been re-certified at C by the
  time it submitted. This names both, compared with the story's certification
  now (issue 746895bf).
  """
  @spec stale_reason(map(), map()) :: String.t() | nil
  def stale_reason(%{stale: true} = attempt, story) do
    reviewed = Map.get(attempt, :reviewed_commit)
    certified = Map.get(story, :qa_ready_commit)

    cond do
      not is_binary(reviewed) ->
        "no review was recorded for it, so it cannot be matched to a certification"

      reviewed != certified and is_binary(certified) ->
        "it reviewed commit #{reviewed}, but the story is certified at #{certified}" <>
          " — a re-certification at a different commit supersedes a pass on the earlier one" <>
          " unless nothing QA exercises changed between them"

      is_nil(certified) ->
        "it reviewed commit #{reviewed}, but the story is not certified for QA now"

      true ->
        "it reviewed the story's certification of #{reviewed} made at #{Map.get(attempt, :review_certified_at)}," <>
          " which has since been replaced, or the issue fixes it saw no longer match those submitted"
    end
  end

  def stale_reason(_attempt, _story), do: nil

  defp render_review(%{
         reviewed_commit: revision,
         reviewed_submissions: submissions,
         review_started_at: started_at
       })
       when is_binary(revision) do
    "reviewed_revision: #{revision}\nreview_started_at: #{started_at}\nreviewed_submissions: #{Jason.encode!(submissions || %{})}"
  end

  defp render_review(_), do: "review: (not recorded)"

  defp render_scenarios([]), do: "  (none)"

  defp render_scenarios(scenarios) do
    Enum.map_join(scenarios, "\n", fn s ->
      blocker = if s.blocker_issue_id, do: " (blocker: #{s.blocker_issue_id})", else: ""
      "  - #{s.name} [#{s.status}]#{blocker} — #{s.observation}"
    end)
  end

  defp render_issue_ids(nil), do: "(none)"
  defp render_issue_ids([]), do: "(none)"
  defp render_issue_ids(ids), do: Enum.join(ids, ", ")

  # 257a6a15: nil and [] are different facts here — nil is an attempt that
  # predates this field or never answered the question; [] is an agent
  # stating outright that it called none. Collapsing them would erase the
  # exact distinction this field exists to preserve.
  defp render_tools_used(nil), do: "(not reported)"
  defp render_tools_used([]), do: "(none — reported explicitly)"
  defp render_tools_used(tools), do: Enum.join(tools, ", ")

  defp render_invalidation(%{invalidations: invalidations})
       when is_list(invalidations) and invalidations != [] do
    Enum.map_join(invalidations, "", fn inv ->
      "\ninvalidated at #{inv.invalidated_at} by user #{inv.invalidated_by_user_id}\n  reason: #{inv.reason}\n  cause: #{inv.cause || "manual"}; actor: #{inv.actor_id || inv.invalidated_by_user_id}; submission: #{inv.submission_ref}"
    end)
  end

  defp render_invalidation(_), do: ""

  defp error_response(reason) when is_atom(reason) or is_binary(reason),
    do: {:error, "list_qa_attempts failed: #{reason}"}

  defp error_response(reason),
    do: {:error, "list_qa_attempts failed: #{inspect(reason)}"}
end
