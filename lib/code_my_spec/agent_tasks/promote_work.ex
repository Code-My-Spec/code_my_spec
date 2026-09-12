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

  defp verdict({false, %{behind: behind, ahead: 0, dirty: false}}, story) when behind > 0 do
    {:ok, :invalid,
     "Story #{story.number}'s work may already be on the running dev copy — this " <>
       "checkout is #{behind} commit(s) behind it and has nothing of its own to send. " <>
       "Merge main in here (`git merge --ff-only main`), then evaluate again."}
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

  # Behind, with nothing of its own to send and a clean tree. Almost always the
  # state a *successful* promotion leaves behind: it merges this branch into the
  # running copy and leaves this worktree where it was, so the worktree is now
  # behind the copy that already has the work.
  #
  # This used to render as "its work is not on the checkout the application runs
  # from ... Call `promote`", which is the inverse of the truth and cost twenty
  # minutes on 2026-09-12 — the running copy's HEAD was literally
  # `Merge branch 'light-harness'`, the promotion's own merge commit. Following
  # the advice restarts the shared dev server and leaves the reader exactly as
  # behind as before.
  #
  # Hedged rather than asserted ("may already be"), because behind-with-nothing-
  # to-send is also what a checkout that never promoted looks like. The remedy is
  # the same either way, and it is cheap and safe, which is what makes it worth
  # stating without proving which case this is.
  defp prompt_for({false, %{behind: behind, ahead: 0, dirty: false}}, story)
       when behind > 0 do
    """
    Story #{story.number} — "#{story.title}" — may already be on the running dev
    copy. This checkout is #{behind} commit(s) behind it and has nothing of its
    own to send, which is the state a successful promotion leaves: promotion
    merges your branch into the running copy and leaves your worktree where it
    was.

    Do NOT call `promote` for this. It would restart the shared dev server and
    leave you exactly as far behind. Catch this checkout up instead:

        git merge --ff-only main

    Then evaluate this task again. If that refuses, this checkout has genuinely
    diverged and `promote` is the right call after all.

    Note `main` here means the checkout the application runs from, not
    `origin/main` — the two differ whenever the running copy holds commits
    nobody has pushed, so `git status` can read 0/0 while this says you are
    behind. Both are correct.
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
