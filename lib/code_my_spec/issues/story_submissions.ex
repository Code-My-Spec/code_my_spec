defmodule CodeMySpec.Issues.StorySubmissions do
  @moduledoc "Story-owned fixes retain their submission identity through shared QA and promotion."

  import Ecto.Query
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Qa.Invalidations
  alias CodeMySpec.Repo

  def list(scope, story_id) do
    Repo.all(query(scope, story_id))
  end

  def snapshot(scope, story_id, threshold),
    do: Map.get(snapshots(scope, [story_id], threshold), story_id, %{})

  def snapshots(scope, story_ids, threshold) do
    from(i in Issue,
      where: i.project_id == ^scope.active_project_id,
      where: i.story_id in ^story_ids and is_nil(i.assigned_working_copy_id),
      where:
        i.status == :accepted or (i.status == :resolved and not is_nil(i.story_submission_ref)),
      # Severity decides which *unsubmitted* issues hold a story back. A fix the coder
      # submitted is a promise to review and land whatever its severity: left out of
      # the snapshot, a low-severity fix is never reviewed, never completed by the
      # landing that carried it, and stays accepted for good (issue 64bd087b).
      where:
        i.severity in ^Issue.severities_at_or_above(threshold) or
          not is_nil(i.story_submission_ref)
    )
    |> Repo.all()
    |> Enum.group_by(& &1.story_id)
    |> Map.new(fn {id, issues} -> {id, Map.new(issues, &{&1.id, &1.story_submission_ref})} end)
  end

  def submitted?(%Issue{story_submission_ref: ref}), do: is_binary(ref)

  def submit(scope, issue, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    if nonblank?(attrs["revision"]) and nonblank?(attrs["evidence"]),
      do: Repo.transaction(fn -> submit_locked(scope, issue, attrs) end),
      else: {:error, :submission_revision_and_evidence_required}
  end

  defp submit_locked(scope, issue, attrs) do
    lock_story!(scope, issue.story_id)
    current = lock_issue!(scope, issue.story_id, issue.id)
    authorize!(scope, current.story_id)

    if same_submission?(current, attrs),
      do: {current, false},
      else: record_submission(scope, current, attrs)
  end

  defp same_submission?(issue, attrs) do
    submitted?(issue) and issue.story_submission_revision == attrs["revision"] and
      issue.story_submission_evidence == attrs["evidence"]
  end

  defp record_submission(scope, issue, attrs) do
    now = DateTime.utc_now()
    ref = Ecto.UUID.generate()

    entry = %{
      "ref" => ref,
      "revision" => attrs["revision"],
      "evidence" => attrs["evidence"],
      "submitted_at" => DateTime.to_iso8601(now)
    }

    updated =
      update!(issue, %{
        story_submission_ref: ref,
        story_submission_revision: attrs["revision"],
        story_submission_evidence: attrs["evidence"],
        story_submitted_at: now,
        story_submission_history: issue.story_submission_history ++ [entry]
      })

    clear_readiness(issue.story_id)

    {:ok, _} =
      Invalidations.invalidate_story_submission(scope, issue.story_id, %{
        issue_id: issue.id,
        submission_ref: ref,
        actor_id: attrs["actor_id"] || scope.user_id || scope.active_working_copy_id
      })

    {updated, true}
  end

  def rework(scope, story_id, snapshot, ids, reason) do
    if nonblank?(reason) do
      mutate_reviewed(scope, story_id, snapshot, ids, fn issue ->
        clear_readiness(story_id)

        history =
          issue.story_submission_history ++
            [
              %{
                "returned_ref" => issue.story_submission_ref,
                "reason" => reason,
                "returned_at" => DateTime.to_iso8601(DateTime.utc_now())
              }
            ]

        update!(issue, %{
          story_submission_ref: nil,
          story_submitted_at: nil,
          story_submission_history: history
        })
      end)
    else
      {:error, :rework_reason_required}
    end
  end

  def complete(scope, story_id, snapshot, commit) do
    if nonblank?(commit) and Enum.all?(snapshot, fn {_id, ref} -> is_binary(ref) end),
      do: Repo.transaction(fn -> complete_locked(scope, story_id, snapshot, commit) end),
      else: {:error, :reviewed_submissions_and_landed_commit_required}
  end

  defp complete_locked(scope, story_id, snapshot, commit) do
    lock_story!(scope, story_id)

    snapshot
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn id ->
      issue = lock_reviewed_issue!(scope, story_id, id)
      assert_current!(issue, snapshot)
      complete_one(issue, commit)
    end)
  end

  defp complete_one(%{status: :resolved, landed_commit: landed} = issue, _commit)
       when is_binary(landed), do: issue

  defp complete_one(%{status: :accepted} = issue, commit),
    do:
      update!(issue, %{
        status: :resolved,
        landed_commit: commit,
        resolution: issue.story_submission_evidence
      })

  defp complete_one(_issue, _commit), do: Repo.rollback(:stale_story_submission)

  defp lock_reviewed_issue!(scope, story_id, id) do
    Repo.one(
      from(i in Issue,
        where:
          i.project_id == ^scope.active_project_id and i.account_id == ^scope.active_account_id,
        where: i.story_id == ^story_id and i.id == ^id and is_nil(i.assigned_working_copy_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_an_inherited_story_issue)
  end

  defp assert_current!(issue, snapshot) do
    unless submitted?(issue) and Map.get(snapshot, issue.id) == issue.story_submission_ref,
      do: Repo.rollback(:stale_story_submission)
  end

  defp clear_readiness(story_id) do
    Repo.update_all(from(s in "stories", where: s.id == ^story_id),
      set: [qa_ready_commit: nil, qa_ready_at: nil]
    )
  end

  defp mutate_reviewed(scope, story_id, snapshot, ids, mutate) do
    Repo.transaction(fn ->
      lock_story!(scope, story_id)

      Enum.map(Enum.sort(Enum.uniq(ids)), fn id ->
        issue = lock_issue!(scope, story_id, id)

        assert_current!(issue, snapshot)

        mutate.(issue)
      end)
    end)
  end

  defp query(scope, story_id) do
    from(i in Issue,
      where:
        i.project_id == ^scope.active_project_id and i.account_id == ^scope.active_account_id,
      where: i.story_id == ^story_id and i.status == :accepted,
      where: is_nil(i.assigned_working_copy_id),
      order_by: i.id
    )
  end

  defp lock_issue!(scope, story_id, id) do
    Repo.one(from(i in query(scope, story_id), where: i.id == ^id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_an_inherited_story_issue)
  end

  defp lock_story!(scope, story_id) when is_integer(story_id) do
    story =
      Repo.one(
        from(s in "stories",
          where: s.id == ^story_id and s.project_id == type(^scope.active_project_id, Ecto.UUID),
          select: s.id,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(story), do: Repo.rollback(:story_not_found)
  end

  defp lock_story!(_scope, _id), do: Repo.rollback(:story_required)

  defp authorize!(%{active_working_copy_id: copy} = scope, story_id) when is_binary(copy) do
    assigned =
      Repo.exists?(
        from(a in "agents",
          where:
            a.working_copy_id == type(^copy, Ecto.UUID) and
              a.project_id == type(^scope.active_project_id, Ecto.UUID) and
              a.story_id == ^story_id and is_nil(a.retired_at) and a.role == "coding"
        )
      )

    unless assigned, do: Repo.rollback(:story_not_assigned_to_working_copy)
  end

  defp authorize!(_scope, _story_id), do: Repo.rollback(:working_copy_required)
  defp update!(issue, attrs), do: issue |> Ecto.Changeset.change(attrs) |> Repo.update!()
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
