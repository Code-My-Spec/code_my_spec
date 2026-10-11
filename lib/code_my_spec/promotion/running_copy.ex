defmodule CodeMySpec.Promotion.RunningCopy do
  @moduledoc """
  Whether a story's code is on the running copy, and whether that copy is
  serving — the `story_promoted` verdict.

  A read of the main working copy and of each story's `promoted_version` stamp,
  nothing more. Its own leaf boundary so that the requirement graph can read it
  without depending on `Promotion`, which sits above the graph (it gates on it,
  runs git and restarts servers). `Promotion` delegates here.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Issues, CodeMySpec.Users.Scope, CodeMySpec.WorkingCopies],
    exports: :all

  alias CodeMySpec.Issues
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc """
  The requirement-graph checker: `{satisfied?, details}`.

  Answers from git state, not from files.

  The version before this compared the story's implementation files against the
  running copy's, and it was insufficient for a case that happens on every
  project: promote a story, QA files an issue, fix the issue on the working
  copy. Whether the fix is back on main is a question about commits, and asking
  it about files means depending on scans landing, on story-to-component
  linkage, and on roles being classified right — three ways to answer "yes" for
  a checkout that is behind.

  That version read the checkout's own git state instead — nothing on it main
  did not have (`commits_ahead_of_main`), no uncommitted changes (`tree_dirty`)
  — deliberately not a third condition, whether main had commits the checkout
  did not (`commits_behind_main`): that was gated once and produced a
  demonstrable false negative. A promotion lands, the story is satisfied, an
  unrelated push by somebody else on the shared box moves main forward, and
  the story un-satisfies even though its own commit is still exactly as much
  an ancestor of main as it ever was. Git history only grows, so once
  `commits_ahead_of_main` reads 0 for a checkout it should stay true forever
  after. See issue `cf06b908`.

  It didn't, though — not for the checkout the answer actually came from. That
  answer was read live off the *checkout*, and a checkout is shared by every
  story an agent ever works on it: promote story A, then start story B on the
  same checkout, and the first new commit or edit re-dirties the very row
  story A's satisfied answer was being read from. Nothing about story A's
  promotion changed; the checkout it happened to land from moved on, and the
  gate could not tell those apart because it was never asking about the
  story, only about the checkout.

  So the answer now lives on the story: `promoted_version`, a stamp
  `Promotion.promote/1` writes once, permanently, the moment a merge actually
  lands that story's code on main. Ancestry only ever grows — once a
  promotion happens it stays true forever, and now nothing but a deliberate
  invalidation (clearing the field to send the story back through this gate)
  can make it stop being true. Whether *this checkout* is right now in sync
  with main is a real question and a different one, and it is answered where
  it can be answered honestly: `promote` runs git in the checkout and reports
  what is holding a merge up. It is not mirrored into `working_copies` any
  more — a cached copy of git's answer could only ever be a staler one.
  """
  @spec running_copy_check(Scope.t(), term()) :: {boolean(), map()}
  def running_copy_check(%Scope{} = scope, entity) do
    scope
    |> WorkingCopies.main()
    |> verdict(scope, with_fix(entity, fixes(scope, [entity])), :unread)
  end

  @doc """
  The same verdict for every story at once.

  Two reads answer this check — which copy is running, and which copy is asking
  — and neither depends on the story. The only per-story input is
  `promoted_version`, so asking per story is the same pair of reads repeated
  once per story to answer a question that already had its answer.

  Returns `{unpromoted_verdict, %{story_id => verdict}}`: the verdict every
  story that has never been promoted gets, and the handful that carry a stamp.
  That is a sweep's default and its exceptions, which is the shape
  `Requirements.Handlers` settles this requirement with and the only reason
  this exists beside `running_copy_check/2`. Both go through `verdict/4`, so
  the per-story path and the set path cannot disagree.
  """
  @spec running_copy_verdicts(Scope.t(), [term()]) ::
          {{boolean(), map()}, %{optional(term()) => {boolean(), map()}}}
  def running_copy_verdicts(%Scope{} = scope, stories) do
    running = WorkingCopies.main(scope)
    local = local_copy(running, scope)

    unpromoted = verdict(running, scope, %{promoted_version: nil}, local)

    stamped = Enum.filter(stories, &is_binary(Map.get(&1, :promoted_version)))
    fixes = fixes(scope, stamped)

    promoted =
      for story <- stamped,
          into: %{},
          do: {story.id, verdict(running, scope, with_fix(story, fixes), local)}

    {unpromoted, promoted}
  end

  # No copy is designated, so nothing is running and nothing can be behind it.
  # Holding every story until somebody designates one would be a wall with no
  # agent able to clear it.
  defp verdict(nil, _scope, _entity, _local), do: {true, %{status: "No running copy designated"}}

  # Working directly on the running copy. There is no branch to merge and
  # nothing an agent could do to a gate that asked for one — John: "it is
  # eminently possible that someone would be just doing the work on Maine."
  #
  # Still has to be serving. The code is here by definition; whether anything
  # is answering is a separate question.
  #
  # Story 1003, revised 2026-09-28: this check no longer gates what QA is
  # about to test — QA now runs against a story's own working copy before
  # promotion (story 1108), and `story_promoted` moved to depend on
  # `qa_complete` rather than the reverse. This verdict answers "has this
  # landed on main and is main serving it," a promotion-completeness fact,
  # not a precondition QA is waiting on.
  defp verdict(
         %WorkingCopy{id: id} = running,
         %Scope{active_working_copy_id: id},
         _entity,
         _local
       ),
       do:
         serving(running, %{
           status: "Working on the running copy: the promotion stamp is not read here"
         })

  defp verdict(%WorkingCopy{}, %Scope{active_working_copy_id: nil}, _entity, _local),
    do: {true, %{status: "No checkout on this scope"}}

  # `:unread` rather than reading the local copy up front, because the two
  # clauses above answer without it — `running_copy_check/2` is called once per
  # story on the path this is the fallback for, and a read those clauses throw
  # away is one per story.
  defp verdict(%WorkingCopy{} = running, %Scope{} = scope, entity, :unread),
    do: verdict(running, scope, entity, local_copy(running, scope))

  # The stamp alone. This used to ask whether main was serving too, so every
  # restart of main — after any promote, app or harness — unsatisfied every
  # promoted story at once, and work handed the first one to a coder who ran
  # the full gate only for `mark_story_promoted` to keep the stamp it already
  # had: 26 paid turns from 09-27 to 10-01 (ccedd2e7). Whether main is up is
  # deploy's question, and since story 1003 QA no longer waits on this one.
  defp verdict(%WorkingCopy{}, %Scope{}, entity, {:ok, copy}),
    do: promoted(entity, copy)

  defp verdict(%WorkingCopy{}, %Scope{}, _entity, _local),
    do: {true, %{status: "This checkout is not on file"}}

  defp local_copy(%WorkingCopy{id: id}, %Scope{active_working_copy_id: here})
       when is_binary(here) and here != id,
       do: WorkingCopies.fetch(here)

  defp local_copy(_running, %Scope{}), do: :none

  # The story's own stamp, not a read of the checkout it happened to be
  # promoted from. Once a promotion sets this, nothing the checkout does
  # afterward — more commits, a dirty tree, work for an unrelated story — can
  # make it stop being true, because it already happened.
  defp promoted(entity, copy) do
    case {Map.get(entity, :promoted_version), unshipped_fix(entity)} do
      {version, nil} when is_binary(version) ->
        {true, %{status: "Promoted at version #{version}"}}

      {version, {issue_id, submitted_at}} when is_binary(version) ->
        fix_not_promoted(version, issue_id, submitted_at)

      _ ->
        not_yet_promoted(copy)
    end
  end

  # A submitted story fix after the last promotion requires a fresh shared QA
  # pass and another landing. Its submission timestamp is stable when the issue
  # is edited or ultimately resolved by promotion.
  defp unshipped_fix(entity) do
    with {_issue_id, submitted_at} = fix <- Map.get(entity, :fix),
         %DateTime{} = promoted_at <- Map.get(entity, :specs_ready_at),
         :gt <- DateTime.compare(submitted_at, promoted_at) do
      fix
    else
      _ -> nil
    end
  end

  defp fix_not_promoted(version, issue_id, submitted_at) do
    {false,
     %{
       reason:
         "issue #{issue_id} on this story was submitted at #{DateTime.to_iso8601(submitted_at)}, " <>
           "after its last promotion (version #{version}), so its fix is not on main yet. " <>
           "Promote this story again by completing its story_promoted task.",
       promoted: false
     }}
  end

  defp fixes(%Scope{active_project_id: project_id}, stories) when is_binary(project_id) do
    stamped_ids =
      for story <- stories,
          is_binary(Map.get(story, :promoted_version)),
          id = Map.get(story, :id),
          id != nil,
          do: id

    case stamped_ids do
      [] -> %{}
      ids -> Issues.latest_story_submissions(project_id, ids)
    end
  end

  defp fixes(_scope, _stories), do: %{}

  defp with_fix(%{id: id} = story, fixes), do: Map.put(story, :fix, Map.get(fixes, id))
  defp with_fix(entity, _fixes), do: entity

  # No git diagnostic any more, and `promote` is a better one than this was.
  #
  # This used to append "this checkout currently has 3 commit(s) not on main;
  # uncommitted changes", read from columns the harness mirrored into
  # `working_copies` on every sync. Those are gone: nothing decided on them, and
  # `Freshness.story/2` hashed them into every story's fingerprint, so a
  # keystroke anywhere reconsidered every story in the project.
  #
  # The advice was also the staler half of a pair. `promote` runs git in the
  # checkout — `git merge --ff-only` is its precondition and its merge in one
  # command — so it answers the same question live, at the moment it matters,
  # and names what to do. A mirrored copy could only ever disagree with it, and
  # `Sync` recorded it doing so: "at 06:01 git said `ahead=0 behind=0` and the
  # row still said `ahead=3`".
  # f4786ba1: says what is read and how to satisfy it, because an agent that
  # checked git instead found the code on main and concluded the gate lied.
  defp not_yet_promoted(%WorkingCopy{}) do
    {false,
     %{
       reason:
         "this story has no promotion stamp: `promoted_version` is unset. It is " <>
           "written only by a promotion that names this story, once its spex pass " <>
           "on the promoting copy — code already on main does not count, and this " <>
           "is not a git check. Promote this story by completing its " <>
           "story_promoted task.",
       promoted: false
     }}
  end

  # Whether the application is answering, asked only of an agent working on the
  # running copy itself (criterion 1183).
  #
  # `story_promoted` proved the code was on the running copy and stopped
  # there, and the two came apart within a day: Broken Oaths' preview was down,
  # this gate was satisfied, and a QA agent stood in front of a connection
  # refused with the graph reporting the story ready to test. It then asked to
  # restart the app itself — which would have started it on code that did not
  # contain the work it was there to verify.
  #
  # Never checked passes. A copy with no preview address has nothing to be up,
  # and a harness that has not reported yet is not evidence of anything; holding
  # every story on either would be a gate no agent can clear.
  defp serving(%WorkingCopy{preview_status: nil}, details), do: {true, details}
  defp serving(%WorkingCopy{preview_status: "serving"}, details), do: {true, details}

  # A 500 is the application answering. That is a QA finding rather than a
  # reason to keep QA away from it — the whole point of testing is to meet it.
  defp serving(%WorkingCopy{preview_status: "erroring"}, details), do: {true, details}

  defp serving(%WorkingCopy{preview_status: "down"} = running, _details) do
    {false,
     %{
       reason:
         "the application is not answering at #{running.preview_url || "its preview address"}, " <>
           "so there is nothing for QA to test. Completing the story_promoted task " <>
           "promotes again, which restarts it.",
       preview_status: "down"
     }}
  end
end
