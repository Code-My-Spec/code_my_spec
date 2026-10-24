defmodule CodeMySpec.Qa.StoryReviews do
  @moduledoc """
  What a story QA pass reviewed, and whether it still answers for the story.

  A review is the story's certification (commit and moment) and its submitted
  issue fixes, captured on the QA task when it starts and copied onto the
  attempt when it submits. Captured at the start because a pass takes an hour:
  a story re-certified while it ran must not be approved by a pass that never
  saw the new commit.
  """
  import Ecto.Query
  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Qa.Verdict
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner

  @doc """
  Whether the latest authoritative result approves the story's certification —
  and, given `commit`, whether that certification is at it. Promotion asks with
  the candidate; anything else asks with `:any`.
  """
  def current_pass?(scope, story_id), do: current_pass?(scope, story_id, :any)

  def current_pass?(%{active_project_id: nil}, _story_id, _commit), do: false

  def current_pass?(scope, story_id, commit) do
    story = read_story(scope, story_id, false)

    with %{} <- story,
         :ok <- ensure_triaged(scope, story_id),
         %QaAttempt{} = attempt <- latest_attempt(story_id),
         true <- Verdict.passed?(attempt) do
      current?(scope, story, Verdict.review_of(attempt)) and certified_at?(story, commit)
    else
      _ -> false
    end
  end

  @doc """
  Why `attempt`, a recorded pass with no invalidations, does not satisfy
  `qa_complete` for `story_id` anyway — or `nil` if it does (or does not
  apply). See `Verdict.currency_gap/3`.
  """
  def currency_gap(scope, story_id, attempt) do
    case read_story(scope, story_id, false) do
      %{} = story -> Verdict.currency_gap(attempt, story, snapshot(scope, story_id))
      _ -> nil
    end
  end

  defp certified_at?(_story, :any), do: true
  defp certified_at?(story, commit), do: story.qa_ready_commit == commit

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

  def complete(scope, story, landed_commit, expected_commit)
      when is_binary(expected_commit) do
    Repo.transaction(fn ->
      locked = lock_story!(scope, story.id)
      attempt = latest_attempt(story.id)

      with :ok <- ensure_triaged(scope, story.id),
           true <- Verdict.passed?(attempt),
           review = Verdict.review_of(attempt),
           true <- current?(scope, locked, review) and certified_at?(locked, expected_commit),
           {:ok, issues} <-
             Issues.complete_story_submissions(scope, story.id, review.submissions, landed_commit) do
        issues
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:no_current_story_qa_pass)
      end
    end)
  end

  @doc """
  Record on `task` what it is about to review, or confirm the review it already
  holds still answers for the story. `{:error, :qa_review_superseded}` when the
  story moved on since it started.
  """
  def capture(%{active_project_id: nil}, _owner, _task), do: {:error, :no_active_project}

  def capture(scope, owner, %{id: task_id, story_id: story_id} = task)
      when is_binary(task_id) and is_integer(story_id) do
    Repo.transaction(fn ->
      story = lock_story!(scope, story_id)

      case review_of_task(task) do
        nil -> start!(scope, owner, story, task_id)
        review -> held!(scope, story, review)
      end
    end)
  end

  def capture(_scope, _owner, _task), do: {:error, :story_review_task_required}

  defp held!(scope, story, review) do
    if current?(scope, story, review), do: review, else: Repo.rollback(:qa_review_superseded)
  end

  @doc """
  A submission counts only while its review still answers for the story and
  no attempt has reviewed a later start; `false` in the third place says so.
  """
  def fetch(scope, task, story_id) do
    story = lock_story!(scope, story_id)

    case review_of_task(task) do
      nil ->
        {:error, :qa_review_not_started}

      review ->
        {:ok, review, current?(scope, story, review) and not newer_result?(story_id, review)}
    end
  end

  @doc """
  The certification a re-certified story keeps as the one QA must have
  reviewed: the one its current pass reviewed, when `changed` — the paths
  between that commit and the new one — touches nothing QA exercises. `nil` when
  there is none, the paths could not be read, or one of them is product.
  """
  @spec carry(map(), [String.t()] | nil) :: {String.t(), DateTime.t()} | nil
  def carry(%{qa_reviewed_commit: commit, qa_reviewed_at: at}, changed)
      when is_binary(commit) and is_list(changed) do
    if product_change?(changed), do: nil, else: {commit, at}
  end

  def carry(_story, _changed), do: nil

  # What QA exercises: the running app and what builds it. A test, spex, doc
  # or `.code_my_spec` change after QA re-certifies without another QA pass
  # (John, 2026-10-11); one of these needs QA again.
  @product_paths ~w(lib/ assets/ priv/ config/ rel/)
  @product_files ~w(mix.exs mix.lock)

  @doc "Whether any of `paths` is something QA exercises."
  def product_change?(paths),
    do:
      Enum.any?(paths, fn path ->
        path in @product_files or Enum.any?(@product_paths, &String.starts_with?(path, &1))
      end)

  def lock_story!(scope, story_id) do
    read_story(scope, story_id, true) || Repo.rollback(:story_not_found)
  end

  defp read_story(scope, story_id, lock?) do
    query =
      from(s in "stories",
        where: s.id == ^story_id and s.project_id == type(^scope.active_project_id, :binary_id),
        select: %{
          id: s.id,
          qa_ready_at: type(s.qa_ready_at, :utc_datetime_usec),
          qa_ready_commit: s.qa_ready_commit,
          qa_reviewed_at: type(s.qa_reviewed_at, :utc_datetime_usec),
          qa_reviewed_commit: s.qa_reviewed_commit
        }
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp start!(scope, owner, story, task_id) do
    submissions = snapshot(scope, story.id)

    cond do
      ensure_triaged(scope, story.id) != :ok ->
        Repo.rollback(:story_issues_not_triaged)

      is_nil(story.qa_ready_at) or is_nil(story.qa_ready_commit) ->
        Repo.rollback(:story_not_certified_for_qa)

      Enum.any?(submissions, fn {_id, ref} -> is_nil(ref) end) ->
        Repo.rollback(:story_issues_not_submitted)

      true ->
        review = %{
          commit: story.qa_ready_commit,
          certified_at: story.qa_ready_at,
          submissions: submissions,
          started_at: DateTime.utc_now()
        }

        case TaskOwner.record_review(scope, owner, task_id, review) do
          {:ok, _owner} -> review
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  # The task as its owner holds it, or as `jsonb` read raw (string keys, times
  # as ISO strings) when the caller found it by id.
  defp review_of_task(task) when is_map(task) do
    case field(task, :review_commit) do
      commit when is_binary(commit) ->
        %{
          commit: commit,
          certified_at: moment(field(task, :review_certified_at)),
          submissions: field(task, :review_submissions) || %{},
          started_at: moment(field(task, :review_started_at))
        }

      _ ->
        nil
    end
  end

  defp review_of_task(_task), do: nil

  defp field(task, key), do: Map.get(task, key) || Map.get(task, Atom.to_string(key))

  defp moment(%DateTime{} = at), do: at

  defp moment(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp moment(_at), do: nil

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

  defp current?(scope, story, review),
    do: Verdict.review_current?(story, review, snapshot(scope, story.id))

  defp snapshot(scope, story_id),
    do:
      Issues.story_submission_snapshot(
        scope,
        story_id,
        Configurations.fix_issues_min_severity(scope)
      )
end
