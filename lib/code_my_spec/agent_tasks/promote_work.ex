defmodule CodeMySpec.AgentTasks.PromoteWork do
  @moduledoc """
  Agent task for getting a story's finished code onto the running dev copy.

  Sits after `qa_complete`, and exists because of what happened without it on
  2026-09-09: nine stories reached QA whose implementation had never left the
  coding agent's worktree. QA failed all nine, correctly — the code it tested
  was not the code that had been written.

  ## Promotion is completing this task (28d72f8a, chunk 3)

  The prompt lists every problem on the copy the promotion gate would block
  on and says to fix them all, then complete. There is no separate `promote`
  call: `evaluate/3` runs the same ordered gate and promotion the tool does
  (`Promotion.promote/3`) — the copy contains main, its tree is clean, every
  analyzer has a clean run at HEAD, the 30fd997f rule — and merges exactly
  that commit, stamping this story.

    * Promoted: the task is valid.
    * Pending (analysis running at HEAD): the task stays open. The runs it
      started, and any already running there, answer the agent when they land
      (`requested_by` and its waiters, `Agents.AnalysisReport`), and
      `Analysis.awaiting_runs?/3` holds its nudges meanwhile. It completes again
      then.
    * Refused (behind main, a dirty tree, problems): the task stays open with
      the refusal as feedback.

  Nothing here cancels the task, and only the stamp satisfies it: the graph
  reads `promoted_version`, so a story already stamped is valid without
  promoting again.

  `evaluate/2` — callers that do not say who owns the task — only reads the
  stamp. The stop hook and the reconciler's background evaluation reach this
  task through the requirement calculator, not here, and must not merge: the
  reconciler runs inside the harness channel a promotion talks to.
  """

  alias CodeMySpec.Promotion
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.Stories

  def dispatch(_node) do
    "Put this working copy's finished work on the checkout the application " <>
      "runs from, so QA tests the code that was written rather than a stale " <>
      "app. Use when a story has passed QA but its code has not reached the " <>
      "running dev copy."
  end

  def command(scope, task) do
    case story_for(scope, task) do
      nil -> {:ok, project_prompt()}
      story -> {:ok, story_prompt(scope, story)}
    end
  end

  @doc "The stamp alone, promoting nothing. See the moduledoc."
  def evaluate(scope, task) do
    case story_for(scope, task) do
      nil -> no_story()
      story -> scope |> Promotion.running_copy_check(story) |> stamp_verdict(story)
    end
  end

  @doc """
  Complete the task: promote the story's HEAD if the gate allows, as the
  `promote` tool does. `owner` is who is completing it; an agent we run is
  told how the restart ended and answered when pending runs land.
  """
  def evaluate(scope, task, owner) do
    case story_for(scope, task) do
      nil -> no_story()
      story -> scope |> Promotion.running_copy_check(story) |> complete(scope, story, owner)
    end
  end

  defp no_story do
    {:ok, :invalid,
     "No story on this task — cannot check whether its code is on the running copy."}
  end

  defp stamp_verdict({true, %{status: status}}, story) do
    {:ok, :valid, "Story #{story.number}'s work is on the running dev copy (#{status})."}
  end

  defp stamp_verdict({false, %{reason: reason}}, story) do
    {:ok, :invalid,
     "Story #{story.number} is not on the running dev copy yet: " <>
       reason <> " " <> complete_again()}
  end

  defp complete({true, _details} = verdict, _scope, story, _owner),
    do: stamp_verdict(verdict, story)

  defp complete({false, _details}, scope, story, owner) do
    scope
    |> PromotionQueue.promote(story.number, notify: agent_id(owner))
    |> promotion_verdict(story)
  end

  # Queued: the task stays open until the candidate lands (the agent is told
  # when it does, and evaluating again then completes it) or is taken out
  # (the agent is told why, and the task is still its to finish).
  defp promotion_verdict({:ok, %{queued: _}} = result, _story) do
    {:ok, :pending, PromotionQueue.queued_text(result)}
  end

  defp promotion_verdict({:ok, %{pending: pending}}, story) do
    {:ok, :pending, pending_text(pending, story)}
  end

  defp promotion_verdict({:ok, _report} = result, _story) do
    {:ok, :valid, Promotion.outcome_text(result)}
  end

  defp promotion_verdict({:error, _reason} = result, _story) do
    {:ok, :invalid, Promotion.outcome_text(result) <> "\n\n" <> complete_again()}
  end

  defp pending_text(%{commit: commit} = pending, story) do
    sources = Enum.join(Map.get(pending, :started, []) ++ Map.get(pending, :running, []), ", ")

    "Story #{story.number} is not promoted yet: analysis running at #{commit} " <>
      "(#{sources}). Nothing was merged and this task stays open. End your turn; " <>
      "you are told as each run lands. When they have, complete this task again " <>
      "(evaluate_task): if they are clean, exactly #{commit} merges and the story " <>
      "is stamped; if not, fix what they found, commit, and complete again."
  end

  defp complete_again do
    "\"Promote again\" here means: fix it, commit, and complete this task again " <>
      "(evaluate_task). Completing it is the promotion."
  end

  # Matched as a struct name rather than a pattern: `CodeMySpec.Agents` is not a
  # dependency of this boundary (see `FixBddSpecs.wait_directive/2`). A session
  # has no process to tell, so it passes nobody.
  defp agent_id(%{__struct__: CodeMySpec.Agents.Agent, id: id}), do: id
  defp agent_id(_owner), do: nil

  defp story_prompt(scope, story) do
    scope
    |> Promotion.running_copy_check(story)
    |> prompt_for(scope, story)
  end

  defp prompt_for({true, _details}, _scope, story) do
    """
    Story #{story.number} — "#{story.title}" — is already on the running dev
    copy. Nothing to promote; evaluate this task to record it.
    """
    |> String.trim()
  end

  defp prompt_for({false, %{reason: reason}}, scope, story) do
    """
    Story #{story.number} — "#{story.title}" — has passed QA, but its work is
    not on the checkout the application runs from yet.

    #{reason}

    #{problems_section(Promotion.blocking_problems(scope))}

    Fix them all, commit, then complete this task (evaluate_task). Completing
    it queues your HEAD for promotion: the tree must be clean, and the queue
    then gates it on top of main, with any candidates ahead of it, by a clean
    run of every analyzer. When that batch is green it lands on main, this
    story is stamped and the application is reloaded.

    The task stays open while it is queued. End your turn: you are told when it
    lands — complete again then and it is done — or why it was taken out of the
    queue, with the findings to fix.
    """
    |> String.trim()
  end

  defp problems_section([]),
    do: "No problem that would block the promotion is recorded on this copy right now."

  defp problems_section(problems) do
    "Problems on this copy that would block the promotion (#{length(problems)}):\n\n" <>
      Promotion.describe_problems(problems)
  end

  defp project_prompt do
    "Promote this working copy's finished work to the running dev copy with " <>
      "`promote`, naming the story you are promoting."
  end

  defp story_for(scope, %{story_id: story_id}) when not is_nil(story_id),
    do: Stories.get_story(scope, story_id)

  defp story_for(_scope, _task), do: nil
end
