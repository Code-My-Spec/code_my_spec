defmodule CodeMySpec.Qa.StoryReviews do
  @moduledoc "Captures QA input identity before execution; result submission never creates a review."
  import Ecto.Query
  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Qa.StoryReview
  alias CodeMySpec.Qa.Verdict
  alias CodeMySpec.Repo

  @doc "Whether the latest authoritative result approves the currently certified submissions."
  def current_pass?(scope, story_id), do: current_pass?(scope, story_id, :any)

  def current_pass?(%{active_project_id: nil}, _story_id, _revision), do: false

  def current_pass?(scope, story_id, expected_revision) do
    story = read_story(scope, story_id, false)
    attempt = latest_attempt(story_id)

    with %{} <- story,
         :ok <- ensure_triaged(scope, story_id),
         true <- Verdict.passed?(attempt),
         %StoryReview{} = review <- attempt.review_id && Repo.get(StoryReview, attempt.review_id) do
      current?(scope, story, review) and revision_matches?(review, expected_revision)
    else
      _ -> false
    end
  end

  defp revision_matches?(_review, :any), do: true
  defp revision_matches?(review, revision), do: review.certified_revision == revision

  defp latest_attempt(story_id) do
    Repo.one(
      from(a in QaAttempt,
        where: a.story_id == ^story_id and not a.stale,
        order_by: [desc_nulls_last: a.review_started_at, desc: a.submitted_at, desc: a.id],
        limit: 1,
        preload: :invalidations
      )
    )
  end

  def complete(scope, story, landed_commit, expected_revision)
      when is_binary(expected_revision) do
    Repo.transaction(fn ->
      locked = lock_story!(scope, story.id)

      attempt = latest_attempt(story.id)

      with :ok <- ensure_triaged(scope, story.id),
           true <- Verdict.passed?(attempt),
           %StoryReview{} = review <-
             attempt.review_id && Repo.get(StoryReview, attempt.review_id),
           true <-
             current?(scope, locked, review) and revision_matches?(review, expected_revision),
           {:ok, issues} <-
             Issues.complete_story_submissions(scope, story.id, review.submissions, landed_commit) do
        issues
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:no_current_story_qa_pass)
      end
    end)
  end

  def capture(%{active_project_id: nil}, _task), do: {:error, :no_active_project}

  def capture(scope, %{id: task_id, story_id: story_id})
      when is_binary(task_id) and is_integer(story_id) do
    Repo.transaction(fn ->
      story = lock_story!(scope, story_id)

      case Repo.get_by(StoryReview, task_id: task_id) do
        %StoryReview{story_id: ^story_id} = review ->
          reuse_current_review!(scope, story, review)

        nil ->
          insert!(scope, story, task_id)

        _ ->
          Repo.rollback(:review_story_mismatch)
      end
    end)
  end

  def capture(_scope, _task), do: {:error, :story_review_task_required}

  defp reuse_current_review!(scope, story, review) do
    if current?(scope, story, review),
      do: review,
      else: Repo.rollback(:qa_review_superseded)
  end

  def fetch(scope, task_id, story_id) do
    story = lock_story!(scope, story_id)

    case Repo.get_by(StoryReview, task_id: task_id, story_id: story_id) do
      nil ->
        {:error, :qa_review_not_started}

      review ->
        {:ok, review, current?(scope, story, review) and not newer_result?(story_id, review)}
    end
  end

  def lock_story!(scope, story_id) do
    read_story(scope, story_id, true) || Repo.rollback(:story_not_found)
  end

  defp read_story(scope, story_id, lock?) do
    query =
      from(s in "stories",
        where: s.id == ^story_id and s.project_id == ^Ecto.UUID.dump!(scope.active_project_id),
        select: %{id: s.id, qa_ready_at: s.qa_ready_at, qa_ready_commit: s.qa_ready_commit}
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp insert!(scope, story, task_id) do
    submissions = snapshot(scope, story.id)

    cond do
      ensure_triaged(scope, story.id) != :ok ->
        Repo.rollback(:story_issues_not_triaged)

      is_nil(story.qa_ready_at) or is_nil(story.qa_ready_commit) ->
        Repo.rollback(:story_not_certified_for_qa)

      Enum.any?(submissions, fn {_id, ref} -> is_nil(ref) end) ->
        Repo.rollback(:story_issues_not_submitted)

      true ->
        %StoryReview{}
        |> StoryReview.changeset(%{
          task_id: task_id,
          story_id: story.id,
          certified_revision: story.qa_ready_commit,
          certified_at: story.qa_ready_at,
          submissions: submissions,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()
    end
  end

  # Triage is eligibility, not review identity. A QA session may itself file
  # incoming findings; those must not make its own result historically stale.
  defp ensure_triaged(scope, story_id) do
    incoming? =
      Repo.exists?(
        from(i in Issue,
          where:
            i.project_id == ^scope.active_project_id and i.story_id == ^story_id and
              i.status == :incoming
        )
      )

    if incoming?, do: {:error, :story_issues_not_triaged}, else: :ok
  end

  defp newer_result?(story_id, review) do
    Repo.exists?(
      from(a in QaAttempt,
        where:
          a.story_id == ^story_id and not a.stale and a.review_started_at > ^review.started_at
      )
    )
  end

  defp current?(scope, story, review) do
    story.qa_ready_commit == review.certified_revision and
      same_time?(story.qa_ready_at, review.certified_at) and
      snapshot(scope, story.id) == review.submissions
  end

  defp same_time?(nil, _), do: false

  defp same_time?(%NaiveDateTime{} = left, right),
    do: NaiveDateTime.compare(left, DateTime.to_naive(right)) == :eq

  defp same_time?(left, right), do: DateTime.compare(left, right) == :eq

  defp snapshot(scope, story_id),
    do:
      Issues.story_submission_snapshot(
        scope,
        story_id,
        Configurations.fix_issues_min_severity(scope)
      )
end
