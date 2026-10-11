defmodule CodeMySpec.Qa.Verdict do
  @moduledoc """
  Whether a story's QA is complete: the read the requirement graph makes.

  A leaf below the graph (John, 2026-09-27: the graph never calls up; its pure
  reads move down). `Qa` sits above the graph — it reaches Agents — so the graph
  reads this rather than `Qa`, and `Qa` delegates here so both answer alike.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Qa.QaAttempt,
      CodeMySpec.Qa.StoryReview,
      CodeMySpec.Issues,
      CodeMySpec.Configurations,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  import Ecto.Query

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Requirement-checker adapter for the `qa_complete` requirement node.

  Called by `RequirementCalculator` via `check_type: :delegate`. Accepts
  `(scope, story)` (the entity shape the calculator passes) and returns a
  `{boolean(), details_map()}` pair suitable for `normalize_delegate_result/1`.
  """
  @spec complete_check(Scope.t(), map()) :: {boolean(), map()}
  def complete_check(%Scope{active_project_id: nil}, _story), do: verdict(false)

  def complete_check(%Scope{active_project_id: project_id} = scope, story) do
    QaAttempt
    |> where([a], a.story_id == ^story.id)
    |> join(:inner, [a], s in assoc(a, :story), on: s.project_id == ^project_id)
    |> where([a], not a.stale)
    |> order_by([a], desc_nulls_last: a.review_started_at, desc: a.submitted_at, desc: a.id)
    |> limit(1)
    |> preload(:invalidations)
    |> Repo.one()
    |> valid_for_story?(scope, story)
    |> verdict()
  end

  @doc """
  The same check, reading the graph context instead of querying per story.

  `RequirementGraph` walks every ready story in one pass, so the two-argument
  form above runs one query per story on every graph computation. The context
  carries the newest attempt for each story with its invalidations already
  loaded. The verdict still comes from `passed?/2`, so the preloaded and
  querying paths cannot disagree about what makes an attempt count.
  """
  def complete_check(%Scope{} = scope, story, ctx) when is_map(ctx) do
    case ctx[:qa_latest_by_story] do
      latest when is_map(latest) ->
        latest
        |> Map.get(story.id)
        |> valid_for_story?(scope, story, ctx[:qa_submission_snapshots])
        |> verdict()

      _ ->
        complete_check(scope, story)
    end
  end

  def complete_check(scope, story, _ctx), do: complete_check(scope, story)

  @doc """
  The wording `qa_complete` carries, from the boolean the attempt decided.

  Public because `Requirements.Handlers` settles this requirement across every
  story from one read, and a row it writes has to read like one a recompute
  wrote.
  """
  @spec verdict(boolean()) :: {boolean(), map()}
  def verdict(true), do: {true, %{status: "QA passed — valid DB attempt exists"}}
  def verdict(false), do: {false, %{reason: "No valid QA pass attempt in DB for this story"}}

  @doc """
  True iff the **most-recent** attempt on the story is `status: :pass` and
  carries no invalidation. A later `:partial` or `:fail` overrides an earlier
  pass.
  """
  @spec complete?(Scope.t(), integer()) :: boolean()
  def complete?(%Scope{active_project_id: nil}, _story_id), do: false

  def complete?(%Scope{active_project_id: project_id} = scope, story_id) do
    story =
      Repo.one(
        from(s in "stories",
          where: s.id == ^story_id and s.project_id == type(^project_id, :binary_id),
          select: %{
            id: s.id,
            qa_ready_at: type(s.qa_ready_at, :utc_datetime_usec),
            qa_ready_commit: s.qa_ready_commit
          }
        )
      )

    case story do
      nil -> false
      story -> elem(complete_check(scope, story), 0)
    end
  end

  defp valid_for_story?(attempt, scope, story, snapshots \\ nil) do
    if passed?(attempt, story.qa_ready_at) do
      attempt = Repo.preload(attempt, :review)

      case attempt.review do
        %{certified_revision: revision, submissions: submissions} ->
          revision == story.qa_ready_commit and
            submissions == current_snapshot(scope, story.id, snapshots)

        _ ->
          false
      end
    else
      false
    end
  end

  defp current_snapshot(_scope, story_id, snapshots) when is_map(snapshots),
    do: Map.get(snapshots, story_id, %{})

  defp current_snapshot(scope, story_id, _snapshots),
    do:
      Issues.story_submission_snapshot(
        scope,
        story_id,
        Configurations.fix_issues_min_severity(scope)
      )

  @doc """
  Whether an attempt counts as a QA pass.

  A pass that was later invalidated is not one — re-QA is required, which is why
  `invalidations` must be empty as well as the status being `:pass`.
  """
  @spec passed?(QaAttempt.t() | nil) :: boolean()
  def passed?(%QaAttempt{
        status: :pass,
        invalidations: [],
        stale: false,
        review_id: id,
        review_started_at: %DateTime{},
        review_certified_at: %DateTime{}
      })
      when is_binary(id), do: true

  def passed?(_), do: false

  @doc """
  Whether an attempt counts as a QA pass that is still live for `story`.

  A revision clears and re-stamps the story's `qa_ready_at`
  (criterion 1902); a pass from before that stamp answered a question the
  story is no longer asking, so it must not keep `qa_complete` satisfied
  (issue 2e7ed919). `qa_ready_at: nil` means the story has never been
  certified ready for QA, so no recorded attempt can qualify.
  """
  @spec passed?(QaAttempt.t() | nil, DateTime.t() | nil) :: boolean()
  def passed?(attempt, qa_ready_at), do: passed?(attempt) and fresh?(attempt, qa_ready_at)

  defp fresh?(_attempt, nil), do: false
  defp fresh?(%{review_certified_at: nil}, _qa_ready_at), do: false

  defp fresh?(attempt, qa_ready_at),
    do: DateTime.compare(attempt.review_certified_at, qa_ready_at) == :eq
end
