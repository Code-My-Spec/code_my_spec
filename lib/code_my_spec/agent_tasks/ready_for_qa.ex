defmodule CodeMySpec.AgentTasks.ReadyForQa do
  @moduledoc """
  Agent task behind `ready_for_qa`: certify a story's working copy before QA
  spends a pass on it.

  John, 2026-10-02: "get rid of tests passing — we shouldn't rely on problems
  anywhere in the graph except on promotion", then: keep the gate before QA,
  but make it work like promotion. So completing this task runs the procedure
  promotion runs, minus "contains main" and the merge
  (`Promotion.certify/3`): a clean tree, a clean run of all four analyzers at
  HEAD's exact commit, and the story's own spex green there — problems scoped
  as at promotion. On success the story is stamped with that commit
  (`Stories.set_qa_ready/4`), and the graph reads the stamp and nothing else.

    * Certified: stamped, and the task is valid.
    * Pending (no clean run at HEAD yet): the gate starts the missing runs as
      its own, explicit ones (`requested_by` the agent), and the task stays
      open; each run answers the agent when it lands, as a promote's do.
    * Refused (a dirty tree, problems, red spex): the task stays open with the
      refusal as feedback.

  `evaluate/2` — a caller that does not say who owns the task — reads the stamp
  only and starts nothing.
  """

  alias CodeMySpec.Promotion
  alias CodeMySpec.Qa
  alias CodeMySpec.Stories

  # The step that makes the story's specs pass, not one that waits for them:
  # a story on an existing surface has no other implementation node, so an
  # agent told to wait cancelled it and was offered it again (bab9a2a5).
  def dispatch(_node) do
    "Make this story's specs pass: implement what they need, fix what the " <>
      "analyzers find, and commit. Then completing it certifies the copy for QA: " <>
      "a clean tree, a clean run of every analyzer at HEAD, and the story's own " <>
      "specs green there."
  end

  def command(scope, task) do
    case story_for(scope, task) do
      nil -> {:ok, "No story on this task — there is nothing to certify for QA."}
      %{qa_ready_commit: commit} = story when is_binary(commit) -> {:ok, already(story, commit)}
      story -> {:ok, prompt(scope, story)}
    end
  end

  # Already certified — by another copy, or before this offer was made (probe
  # 1870). Agents handed the full prompt re-did the certification from scratch,
  # up to 170s and two dozen calls, for a stamp that was already there.
  defp already(story, commit) do
    "Story #{story.number} is certified ready for QA at #{commit}. Complete this task " <>
      "with `evaluate_task`: it stands if that is still your HEAD, and re-certifies " <>
      "there if it is not."
  end

  @doc "The stamp alone, certifying nothing. See the moduledoc."
  def evaluate(scope, task) do
    case story_for(scope, task) do
      nil -> no_story()
      story -> stamp_verdict(story)
    end
  end

  @doc """
  Complete the task: certify the copy at HEAD and stamp the story. `owner` is
  who is completing it; an agent we run is answered when pending runs land.
  """
  # Certified means at a commit: a stamp the branch has moved past is not a
  # certification of what is there now, so completing re-certifies at HEAD
  # rather than reading the old stamp back.
  def evaluate(scope, task, owner) do
    case story_for(scope, task) do
      nil ->
        no_story()

      story ->
        scope |> Promotion.certify(story, notify: agent_id(owner)) |> certified(scope, story)
    end
  end

  defp no_story, do: {:ok, :invalid, "No story on this task — there is nothing to certify."}

  defp stamp_verdict(%{qa_ready_commit: commit} = story) when is_binary(commit),
    do: {:ok, :valid, "Story #{story.number} is ready for QA, certified at #{commit}."}

  defp stamp_verdict(story),
    do: {:ok, :invalid, "Story #{story.number} is not certified for QA yet. " <> complete_again()}

  # A clean certifying run stamps the story: every red spex refuses it at
  # certification, so clean means every criterion's spex is green.
  defp certified({:ok, %{head: head}}, _scope, %{qa_ready_commit: head} = story),
    do: stamp_verdict(story)

  # A new commit is certified on its own merits. The QA it still needs is the
  # pass the story already has, if nothing QA exercises changed since the commit
  # that pass reviewed (John, 2026-10-11); otherwise a fresh one.
  defp certified({:ok, %{head: head}}, scope, story) do
    reviewed = Qa.carry(story, Promotion.changed_paths(scope, story.qa_reviewed_commit, head))
    {:ok, stamped} = Stories.set_qa_ready(scope, story, head, DateTime.utc_now(), reviewed)
    stamp_verdict(stamped)
  end

  defp certified({:pending, pending}, _scope, story),
    do: {:ok, :pending, pending_text(pending, story)}

  defp certified({:error, %{reason: reason}}, _scope, story),
    do:
      {:ok, :invalid,
       "Story #{story.number} is not ready for QA: #{reason}\n\n" <> complete_again()}

  defp pending_text(%{commit: commit} = pending, story) do
    sources = Enum.join(Map.get(pending, :started, []) ++ Map.get(pending, :running, []), ", ")

    "Story #{story.number} is not certified yet: analysis running at #{commit} " <>
      "(#{sources}). This task stays open. End your turn; you are told as each run " <>
      "lands. Then complete this task again (evaluate_task): if they are clean, " <>
      "#{commit} is stamped ready for QA; if not, fix what they found, commit, and " <>
      "complete again."
  end

  defp complete_again do
    "Fix it, commit, and complete this task again (evaluate_task). Completing it " <>
      "is the certification."
  end

  defp prompt(scope, story) do
    """
    Story #{story.number} — "#{story.title}" — has its specs written. Before QA
    spends a pass on it, this copy is certified the way a promotion certifies one.

    #{problems_section(Promotion.blocking_problems(scope))}

    Make the story's specs pass and fix everything above, commit, then complete
    this task (evaluate_task). Completing it checks that the tree is clean, that
    every analyzer has a clean run at your HEAD, and that this story's own specs
    are green there; then it stamps the story ready for QA at that commit.

    If a run at your HEAD is missing or still running, completing starts it and
    the task stays open. End your turn: you are told when each run lands, and you
    complete again then.
    """
    |> String.trim()
  end

  defp problems_section([]),
    do: "No problem that would block the certification is recorded on this copy right now."

  defp problems_section(problems) do
    "Problems on this copy that would block it (#{length(problems)}):\n\n" <>
      Promotion.describe_problems(problems)
  end

  # As in `PromoteWork`: `CodeMySpec.Agents` is not a dependency of this
  # boundary, and a session has no process to tell.
  defp agent_id(%{__struct__: CodeMySpec.Agents.Agent, id: id}), do: id
  defp agent_id(_owner), do: nil

  defp story_for(scope, %{story_id: story_id}) when not is_nil(story_id),
    do: Stories.get_story(scope, story_id)

  defp story_for(_scope, _task), do: nil
end
