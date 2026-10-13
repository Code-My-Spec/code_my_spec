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
      CodeMySpec.Agents.Agent,
      CodeMySpec.Qa.QaAttempt,
      CodeMySpec.Qa.Verdict,
      CodeMySpec.Configurations,
      CodeMySpec.Environments,
      CodeMySpec.Issues,
      CodeMySpec.Paths,
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.TaskOwner,
      CodeMySpec.Uploads,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  alias CodeMySpec.Qa.{Invalidations, IssueQaAttempts, QaAttempts, Verdict}

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
  Submit a QA outcome for an issue (story 1091), as the agent testing it.

  A pass sends the coder to promote the fix (or, if it already landed,
  resolves the issue and frees the team); anything else leaves the issue open
  and bound, and sends the fix back to the coder.
  """
  defdelegate submit_issue_qa_result(scope, owner, params), to: IssueQaAttempts, as: :submit

  @doc "An issue's fix landed on main: resolve it if its QA passed, else QA's turn."
  defdelegate issue_fix_landed(scope, issue_id, commit), to: IssueQaAttempts, as: :fix_landed

  @doc "Whether an issue's latest QA attempt is a pass."
  defdelegate issue_qa_passed?(scope, issue_id), to: IssueQaAttempts, as: :passed?

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

  @doc "The `qa_complete` check; see `CodeMySpec.Qa.Verdict`."
  defdelegate complete_check(scope, story), to: Verdict
  defdelegate complete_check(scope, story, ctx), to: Verdict

  @doc "The wording `qa_complete` carries; see `CodeMySpec.Qa.Verdict.verdict/1`."
  defdelegate verdict(passed?), to: Verdict
end
