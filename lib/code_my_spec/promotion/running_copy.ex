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
    deps: [CodeMySpec.Issues, CodeMySpec.Users.Scope, CodeMySpec.WorkingCopies]

  alias CodeMySpec.Issues
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc """
  The requirement-graph checker: `{satisfied?, details}`.

  Answers from the story's own `promoted_version` stamp, which
  `Promotion.record_landed_stories/4` writes when a landing carries that story
  onto main. Nothing the checkout does afterwards can unsatisfy it; only
  clearing the stamp, or a story fix submitted after the last promotion, does.
  Whether a checkout is in sync with main is `promote`'s question, answered
  live by git. See knowledge/promotion, "Running-copy verdict".
  """
  @spec running_copy_check(Scope.t(), term()) :: {boolean(), map()}
  def running_copy_check(%Scope{} = scope, entity) do
    scope
    |> WorkingCopies.main()
    |> verdict(scope, with_fix(entity, fixes(scope, [entity])), :unread)
  end

  @doc """
  The same verdict for every story at once.

  Returns `{unpromoted_verdict, %{story_id => verdict}}`: the verdict every
  unstamped story gets, and one per stamped story — a sweep's default and its
  exceptions, the shape `Requirements.Handlers` settles with. Both paths go
  through `verdict/4`, so they cannot disagree.
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

  # No copy designated: passes, since no agent could clear a gate on it.
  defp verdict(nil, _scope, _entity, _local), do: {true, %{status: "No running copy designated"}}

  # Working directly on the running copy: the code is here by definition, so
  # only whether the app is serving is asked.
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

  # `:unread`: the local copy is read only when the clauses above did not
  # answer, saving a read per story.
  defp verdict(%WorkingCopy{} = running, %Scope{} = scope, entity, :unread),
    do: verdict(running, scope, entity, local_copy(running, scope))

  # The stamp alone, never whether main is serving: every restart of main
  # would otherwise unsatisfy every promoted story at once.
  defp verdict(%WorkingCopy{}, %Scope{}, entity, {:ok, copy}),
    do: promoted(entity, copy)

  defp verdict(%WorkingCopy{}, %Scope{}, _entity, _local),
    do: {true, %{status: "This checkout is not on file"}}

  defp local_copy(%WorkingCopy{id: id}, %Scope{active_working_copy_id: here})
       when is_binary(here) and here != id,
       do: WorkingCopies.fetch(here)

  defp local_copy(_running, %Scope{}), do: :none

  # The story's own stamp, not a read of the checkout it was promoted from.
  defp promoted(entity, copy) do
    case {Map.get(entity, :promoted_version), unshipped_fix(entity)} do
      {version, nil} when is_binary(version) ->
        {true, %{status: "Promoted at version #{version}"}}

      {version, {issue_id, submitted_at, open?}} when is_binary(version) ->
        fix_not_promoted(version, issue_id, submitted_at, open?)

      _ ->
        not_yet_promoted(copy)
    end
  end

  # A submitted story fix requires a fresh shared QA pass and a landing that
  # completes it, in two cases: it was submitted after the last promotion (its
  # timestamp is stable when the issue is edited or ultimately resolved), or it is
  # still open — no landing has completed it — whenever it was submitted (issue
  # 04c1f5c1: a story promoted after a fix was submitted, by a landing that did
  # not complete that fix, read as shipped and was never offered a promotion).
  #
  # A stamp with no `specs_ready_at` predates that column: every submitted fix
  # counts as newer than it, never as "no fix".
  defp unshipped_fix(entity) do
    case Map.get(entity, :fix) do
      {_issue_id, _submitted_at, true} = fix ->
        fix

      {_issue_id, submitted_at, _open?} = fix ->
        if after_promotion(submitted_at, Map.get(entity, :specs_ready_at)) == :gt,
          do: fix

      nil ->
        nil
    end
  end

  defp after_promotion(_submitted_at, nil), do: :gt
  defp after_promotion(submitted_at, promoted_at), do: DateTime.compare(submitted_at, promoted_at)

  defp fix_not_promoted(version, issue_id, submitted_at, true) do
    {false,
     %{
       reason:
         "issue #{issue_id} on this story was submitted at #{DateTime.to_iso8601(submitted_at)} and " <>
           "no promotion has completed it (last promotion: version #{version}), so its fix is " <>
           "not on main yet. Promote this story again by completing its story_promoted task.",
       promoted: false
     }}
  end

  defp fix_not_promoted(version, issue_id, submitted_at, false) do
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

  # Says what is read and how to satisfy it: an agent that checked git found
  # the code on main and concluded the gate lied.
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

  # Whether the app is answering, asked only of an agent on the running copy.
  # Never checked passes: no preview address, or a harness that has not
  # reported, is not evidence of anything.
  defp serving(%WorkingCopy{preview_status: nil}, details), do: {true, details}
  defp serving(%WorkingCopy{preview_status: "serving"}, details), do: {true, details}

  # A 500 is the app answering: a QA finding, not a reason to keep QA away.
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
