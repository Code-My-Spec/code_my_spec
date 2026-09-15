defmodule CodeMySpec.AgentTasks.PromoteWork do
  @moduledoc """
  Agent task for getting a story's finished code onto the running dev copy.

  Sits between `bdd_specs_passing` and `qa_complete`, and exists because of
  what happened without it on 2026-09-09: nine stories reached QA whose
  implementation had never left the coding agent's worktree. QA failed all
  nine, correctly — the code it tested was not the code that had been written.

  The work itself is one tool call. This task's job is to say so, and to name
  which files are behind so the agent can tell "I have not promoted yet" from
  "something else is wrong".

  ## The hedge that used to live here

  A behind-only, ahead-0, clean checkout — exactly the state a *successful*
  promotion leaves behind, since promotion merges this branch into the running
  copy and leaves this worktree where it was — used to reach here as a
  refusal, and this task hedged around it ("may already be on the running dev
  copy ... merge main in, then evaluate again") rather than telling the agent
  it was actually done. That cost twenty minutes on 2026-09-12.

  Issue cf06b908 fixed the actual defect one layer down instead:
  `Promotion.running_copy_check/2` no longer gates on `commits_behind_main` at
  all, because ancestry already proves this
  checkout's work is on main and only grows more true as main gains commits
  nobody here wrote. A behind-only checkout now reaches `verdict/2` and
  `prompt_for/2` as `{true, _}`, the same as any other satisfied checkout, so
  the hedge had nothing left to catch and was removed with it.

  `running_copy_check/2` has since moved past ancestry too: it reads the
  story's own `promoted_version` stamp rather than any live column on the
  checkout. The reasoning here still holds — a behind-only checkout's work
  was never actually missing — it is just answered a different way now,
  permanently, by a promotion having actually stamped this story rather than
  by the checkout's ancestry happening to read clean at query time.
  """

  alias CodeMySpec.Promotion
  alias CodeMySpec.Stories

  def dispatch(_node) do
    "Put this working copy's finished work on the checkout the application " <>
      "runs from, so QA tests the code that was written rather than a stale " <>
      "app. Use when a story's specs are green but its code has not reached " <>
      "the running dev copy."
  end

  def command(scope, task) do
    case story_for(scope, task) do
      nil -> {:ok, project_prompt()}
      story -> {:ok, story_prompt(scope, story)}
    end
  end

  def evaluate(scope, task) do
    case story_for(scope, task) do
      nil ->
        {:ok, :invalid,
         "No story on this task — cannot check whether its code is on the running copy."}

      story ->
        scope
        |> Promotion.running_copy_check(story)
        |> verdict(story)
    end
  end

  defp verdict({true, %{status: status}}, story) do
    {:ok, :valid, "Story #{story.number}'s work is on the running dev copy (#{status})."}
  end

  defp verdict({false, %{reason: reason}}, story) do
    {:ok, :invalid,
     "Story #{story.number} is not on the running dev copy yet: " <>
       reason <> " Run `promote` — it gates, merges and restarts."}
  end

  defp story_prompt(scope, story) do
    scope
    |> Promotion.running_copy_check(story)
    |> prompt_for(story)
  end

  defp prompt_for({true, _details}, story) do
    """
    Story #{story.number} — "#{story.title}" — is already on the running dev
    copy. Nothing to promote; evaluate this task to record it.
    """
    |> String.trim()
  end

  defp prompt_for({false, %{reason: reason}}, story) do
    """
    Story #{story.number} — "#{story.title}" — has passing specs, but its work
    is not on the checkout the application runs from. QA tests that checkout,
    so testing now would fail the story for code that was never there.

    #{reason}

    Call `promote`. It refuses if this copy carries problems or uncommitted
    work, and tells you what to fix; otherwise it merges to the running copy,
    restarts the application, and reports the revision being served.
    """
    |> String.trim()
  end

  defp project_prompt do
    "Promote this working copy's finished work to the running dev copy with " <>
      "`promote`."
  end

  defp story_for(scope, %{story_id: story_id}) when not is_nil(story_id),
    do: Stories.get_story(scope, story_id)

  defp story_for(_scope, _task), do: nil
end
