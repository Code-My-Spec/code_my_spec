defmodule CodeMySpec.AgentTasks.IssuePromote do
  @moduledoc """
  Land the fix for a team's issue on main, once QA has passed it (story 1091,
  promote-queue 2026-10-04). `PromoteWork`'s twin for an issue.

  Completing it queues the copy's HEAD as the issue's fix (`PromotionQueue`
  names the issue assigned to the copy). It stays open while the candidate
  waits: the landing resolves the issue and frees the team
  (`Qa.issue_fix_landed/3`), after which completing it again passes. Taken out
  of the queue, the agent is told why, and the task is still its to finish.
  """

  alias CodeMySpec.Issues
  alias CodeMySpec.PromotionQueue

  def dispatch(_node) do
    "Land your team's QA-passed fix on main through the promotion queue: " <>
      "complete this task to queue it."
  end

  @doc "Read the assigned issue and build the prompt. Returns `{:ok, prompt_text}`."
  def command(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      nil -> {:error, "Issue #{task.issue_id} no longer exists."}
      issue -> {:ok, build_prompt(issue, task)}
    end
  end

  @doc "Whether the issue is resolved, queueing nothing."
  def evaluate(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      %{status: :resolved} -> {:ok, :valid}
      nil -> {:ok, :invalid, "Issue #{task.issue_id} no longer exists."}
      issue -> {:ok, :invalid, "The fix for issue #{issue.id} has not landed on main yet."}
    end
  end

  @doc "Complete the task: queue the fix, unless the issue is already resolved."
  def evaluate(scope, task, owner) do
    case Issues.get_issue(scope, task.issue_id) do
      %{status: :resolved} ->
        {:ok, :valid}

      nil ->
        {:ok, :invalid, "Issue #{task.issue_id} no longer exists."}

      _issue ->
        scope
        |> PromotionQueue.promote(nil, notify: agent_id(owner))
        |> verdict()
    end
  end

  # Queued: open until the fix lands (the agent is told, and completing again
  # then passes) or is taken out (the agent is told why).
  defp verdict({:ok, %{queued: _}} = result), do: {:ok, :pending, PromotionQueue.text(result)}
  defp verdict({:ok, _report} = result), do: {:ok, :valid, PromotionQueue.text(result)}
  defp verdict({:error, _reason} = result), do: {:ok, :invalid, PromotionQueue.text(result)}

  # A struct name rather than a pattern, as in `PromoteWork`: `CodeMySpec.Agents`
  # is not a dependency of this boundary.
  defp agent_id(%{__struct__: CodeMySpec.Agents.Agent, id: id}), do: id
  defp agent_id(_owner), do: nil

  defp build_prompt(issue, task) do
    """
    # Land the fix for issue #{issue.id}

    **#{issue.title}** [#{issue.severity}]

    QA has passed your team's fix. Commit everything, then call `evaluate_task` \
    with task_id "#{task.id}" to queue this copy's HEAD for promotion. The queue \
    gates it with the candidates ahead of it and lands it on main; the landing \
    resolves the issue and frees your team. You are told when it lands, or why \
    it was taken out — then fix what it names, commit, and complete this task again.
    """
  end
end
