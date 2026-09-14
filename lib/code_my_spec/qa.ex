defmodule CodeMySpec.Qa do
  @moduledoc """
  Per-story QA workflow context.

  Owns the typed-event audit trail for QA attempts on stories.
  Replaces the file-parsing evaluator in `CodeMySpec.AgentTasks.QaStory`
  with DB-backed events submitted through dedicated MCP tools.

  ## Surfaces

  - **Agent**: `submit_qa_result/2` — single tool call per attempt;
    findings flow through `CodeMySpec.Issues.create_issue/2` and are
    referenced by id in the submit payload.
  - **Engineer (programmatic)**: `list_qa_attempts/2` —
    most-recent-first history of attempts for a story, including
    invalidation events and parent_attempt_id chain.
  - **Engineer (audit action)**: `invalidate_qa_attempt/3` — marks an
    attempt invalidated with audit-stamped (who/when/why); preserves
    the original; `qa_complete?/2` re-clamps if no other valid pass
    remains.
  - **Engineer (browser)**: rendered into the local LiveView story
    page by `CodeMySpecLocalWeb.StoryLive`.

  ## Contract source of truth

  The behavioural contract for this context is the BDD spex suite at
  `test/spex/726_*` and `test/spex/727_*`. Implementation modules
  delegated to from here (`QaAttempts`, `Invalidations`) realise the
  contract; this module is the public boundary.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Environments,
      CodeMySpec.Issues,
      CodeMySpec.Paths,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Sessions,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all

  alias CodeMySpec.Qa.{Invalidations, QaAttempts}
  alias CodeMySpec.Users.Scope

  @doc """
  Submit a QA outcome for an active qa_complete task.

  Creates an immutable attempt row. Multiple submissions on the same
  task are allowed — each creates a new attempt; the latest is
  canonical for `qa_complete?/2`. Only `status: :pass` satisfies
  `qa_complete`.

  See spex `CodeMySpecSpex.Story726.*` for the full contract.
  """
  defdelegate submit_qa_result(scope, params), to: QaAttempts, as: :submit

  @doc """
  List QA attempts for a story, most-recent first.

  Each entry carries status, agent, scenarios, linked issue_ids,
  submitted_at, parent_attempt_id, and any invalidation event with
  its reason. See `CodeMySpecSpex.Story727.Criterion6455Spex`.
  """
  defdelegate list_qa_attempts(scope, story_id), to: QaAttempts, as: :list

  @doc """
  List QA attempts across the active project's stories.

  See `CodeMySpec.Qa.QaAttempts.list_project/2` for option semantics
  (`:include_older`, `:include_invalidated`). Drives the project-wide
  engineer surface — see `CodeMySpecSpex.Story727.Criterion6474Spex`
  / `Criterion6475Spex`.
  """
  defdelegate list_project_attempts(scope, opts \\ []), to: QaAttempts, as: :list_project

  @doc """
  Invalidate a prior passed attempt with a non-empty reason.

  Audit-stamped (engineer id, timestamp, reason). The original
  attempt row is preserved. If no other valid pass remains on the
  story, `qa_complete?/2` re-clamps to false.

  See `CodeMySpecSpex.Story727.Criterion6456Spex` /
  `Criterion6457Spex`.
  """
  defdelegate invalidate_qa_attempt(scope, attempt_id, reason),
    to: Invalidations,
    as: :invalidate

  @doc """
  Is `qa_complete` satisfied for the story?

  True iff the **most-recent** attempt on the story is `status: :pass`
  and carries no invalidation. Not "at least one pass exists" — a later
  `:partial` or `:fail` overrides an earlier pass. Filesystem state
  (legacy `result_complete.md`) is not consulted.
  """
  defdelegate qa_complete?(scope, story_id), to: QaAttempts, as: :complete?

  @doc """
  Requirement-checker adapter for the `qa_complete` requirement node.

  Called by `RequirementCalculator` via `check_type: :delegate`. Accepts
  `(scope, story)` (the entity shape the calculator passes) and returns a
  `{boolean(), details_map()}` pair suitable for `normalize_delegate_result/1`.
  """
  @spec complete_check(Scope.t(), map()) :: {boolean(), map()}
  def complete_check(%Scope{} = scope, story) do
    story_id = story.id

    if QaAttempts.complete?(scope, story_id) do
      {true, %{status: "QA passed — valid DB attempt exists"}}
    else
      {false, %{reason: "No valid QA pass attempt in DB for story #{story_id}"}}
    end
  end

  @doc """
  The same check, reading the graph context instead of querying per story.

  `RequirementGraph` walks every ready story in one pass, so the two-argument
  form above runs one query per story on every graph computation — and the graph
  is recomputed on every stop hook. The context carries the newest attempt for
  each story with its invalidations already loaded.

  The verdict still comes from `QaAttempts.passed?/1`, so the preloaded and
  querying paths cannot disagree about what makes an attempt count.
  """
  def complete_check(%Scope{} = scope, story, ctx) when is_map(ctx) do
    case ctx[:qa_latest_by_story] do
      latest when is_map(latest) ->
        if QaAttempts.passed?(Map.get(latest, story.id)) do
          {true, %{status: "QA passed — valid DB attempt exists"}}
        else
          {false, %{reason: "No valid QA pass attempt in DB for story #{story.id}"}}
        end

      _ ->
        complete_check(scope, story)
    end
  end

  def complete_check(scope, story, _ctx), do: complete_check(scope, story)
end
