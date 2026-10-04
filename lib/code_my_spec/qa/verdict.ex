defmodule CodeMySpec.Qa.Verdict do
  @moduledoc """
  Whether a story's QA is complete: the read the requirement graph makes.

  A leaf below the graph (John, 2026-09-27: the graph never calls up; its pure
  reads move down). `Qa` sits above the graph — it reaches Agents — so the graph
  reads this rather than `Qa`, and `Qa` delegates here so both answer alike.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Qa.QaAttempt, CodeMySpec.Repo, CodeMySpec.Users.Scope],
    exports: :all

  import Ecto.Query

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
  def complete_check(%Scope{} = scope, story),
    do: scope |> complete?(story.id) |> verdict()

  @doc """
  The same check, reading the graph context instead of querying per story.

  `RequirementGraph` walks every ready story in one pass, so the two-argument
  form above runs one query per story on every graph computation. The context
  carries the newest attempt for each story with its invalidations already
  loaded. The verdict still comes from `passed?/1`, so the preloaded and
  querying paths cannot disagree about what makes an attempt count.
  """
  def complete_check(%Scope{} = scope, story, ctx) when is_map(ctx) do
    case ctx[:qa_latest_by_story] do
      latest when is_map(latest) ->
        latest |> Map.get(story.id) |> passed?() |> verdict()

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

  def complete?(%Scope{active_project_id: project_id}, story_id) do
    QaAttempt
    |> where([a], a.story_id == ^story_id)
    |> join(:inner, [a], s in assoc(a, :story), on: s.project_id == ^project_id)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> limit(1)
    |> preload(:invalidations)
    |> Repo.one()
    |> passed?()
  end

  @doc """
  Whether an attempt counts as a QA pass.

  A pass that was later invalidated is not one — re-QA is required, which is why
  `invalidations` must be empty as well as the status being `:pass`.
  """
  @spec passed?(QaAttempt.t() | nil) :: boolean()
  def passed?(%QaAttempt{status: :pass, invalidations: []}), do: true
  def passed?(_), do: false
end
