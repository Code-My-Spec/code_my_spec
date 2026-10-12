defmodule CodeMySpec.Sessions.Task do
  @moduledoc """
  Embedded schema for tasks tracked within a session.

  Each task represents a unit of work the agent is performing — tied to a
  requirement and its satisfied_by agent task module. Tasks are embedded
  in the Session record as a JSONB array.

  Active tasks may be blocked on a durable request. Resolving the request
  leaves the task blocked until its owner explicitly resumes or cancels it.
  Prepared remains a legacy session draft state.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Sessions.SessionType

  @statuses [:prepared, :active, :blocked, :completed, :failed, :cancelled]
  # `:issue` is the machine-resolvable one. A question or a tap_out waits on a
  # person; an issue waits on another role finishing work, and resolving it is
  # something the system can see. Without it QA had to raise a tap_out — a
  # human gate — to express "I am waiting on the bug I just filed", which is
  # how one story took three mechanical denials to get through QA (af9e52c6).
  @blocker_types [:question, :tap_out, :manual, :issue]
  @validation_types [:automatic, :manual]
  @execution_types [:main_agent, :sub_agent]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: atom() | nil,
          session_type: SessionType.t() | nil,
          validation_type: :automatic | :manual | nil,
          execution_type: :main_agent | :sub_agent | nil,
          requirement_id: integer() | nil,
          requirement_name: String.t() | nil,
          component_id: String.t() | nil,
          component_module_name: String.t() | nil,
          story_id: integer() | nil,
          issue_id: String.t() | nil,
          project_id: String.t() | nil,
          agent_id: String.t() | nil,
          expected_files: [String.t()],
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          blocked_at: DateTime.t() | nil,
          blocker_type: :question | :tap_out | :manual | nil,
          blocker_id: String.t() | nil,
          blocker_resolved_at: DateTime.t() | nil,
          blocked_reason: String.t() | nil,
          evaluation_feedback: String.t() | nil,
          evaluation_feedback_count: non_neg_integer()
        }

  @primary_key false
  embedded_schema do
    field :id, :string
    field :status, Ecto.Enum, values: @statuses, default: :prepared
    field :session_type, SessionType
    field :validation_type, Ecto.Enum, values: @validation_types, default: :automatic
    field :execution_type, Ecto.Enum, values: @execution_types, default: :main_agent
    field :requirement_id, :integer
    field :requirement_name, :string
    field :component_id, :string
    field :component_module_name, :string
    field :story_id, :integer
    # Story 1091: the issue this task is fixing or QA-ing, for a task
    # created off `AssignIssueToWorkingCopy` rather than the requirement graph.
    field :issue_id, :string
    field :project_id, :string
    field :agent_id, :string
    # Story 1091, issue e515bff3: a `promote_issue`/`story_promoted` task waits on
    # the queue, not on the agent, so it must not hold the one-task slot. While
    # main was red a batch could not land, the task could not close, and the
    # agent stayed parked on work it could take no action on.
    #
    # The wait is recorded here, on the task itself, by `TaskOwner.await_promotion/3`
    # when the MCP `promote` tool hears `:queued` — deliberately, and not read
    # back off the queue. `Agents.Work` does read `PromotionQueue.open_for/3` for
    # the same question, but it sits above the queue; `TaskOwner` sits below it,
    # so a read from there would close `Qa -> TaskOwner -> PromotionQueue -> Qa`
    # (issue e23a5547). One writer above both, one reader on its own row.
    field :awaiting_subject_id, :string
    field :awaiting_subject_type, :string
    field :expected_files, {:array, :string}, default: []
    # Microsecond resolution so a task's started_at lands strictly past
    # any file's mtime that was synced moments earlier in the same
    # request. Eliminates the need for `Process.sleep(1_100)` in spex
    # that want the pipeline to short-circuit on no-file-changes.
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :blocked_at, :utc_datetime_usec
    field :blocker_type, Ecto.Enum, values: @blocker_types
    field :blocker_id, :string
    field :blocker_resolved_at, :utc_datetime_usec
    field :blocked_reason, :string
    field :evaluation_feedback, :string
    field :evaluation_feedback_count, :integer, default: 0

    # A story QA task's review, captured when it starts (`Qa.StoryReviews`):
    # the certification it is testing and the story's submitted issue fixes.
    # Its result is copied onto the attempt, so the pass records what it saw
    # even if the story is re-certified while it runs.
    field :review_commit, :string
    field :review_certified_at, :utc_datetime_usec
    field :review_submissions, :map
    field :review_started_at, :utc_datetime_usec
  end

  @doc """
  Every status a task can hold.

  Public because `list_tasks` kept its own copy and the two drifted: `:blocked`
  arrived here and not there, so filtering for it answered "Invalid status" for
  a state the schema had been writing for days. A second list of the same thing
  is a list that will disagree.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Every blocker kind a blocked task can name."
  @spec blocker_types() :: [atom()]
  def blocker_types, do: @blocker_types

  @doc "Changeset for creating or updating a task."
  def changeset(task \\ %__MODULE__{}, attrs) do
    task
    |> cast(attrs, [
      :id,
      :status,
      :session_type,
      :validation_type,
      :execution_type,
      :requirement_id,
      :requirement_name,
      :component_id,
      :component_module_name,
      :story_id,
      :issue_id,
      :project_id,
      :agent_id,
      :expected_files,
      :started_at,
      :completed_at,
      :blocked_at,
      :blocker_type,
      :blocker_id,
      :blocker_resolved_at,
      :blocked_reason,
      :evaluation_feedback,
      :evaluation_feedback_count,
      :review_commit,
      :review_certified_at,
      :review_submissions,
      :review_started_at
    ])
    |> validate_required([:id, :status])
    |> put_id_if_missing()
  end

  defp put_id_if_missing(changeset) do
    case fetch_field(changeset, :id) do
      {_source, nil} -> put_change(changeset, :id, Ecto.UUID.generate())
      :error -> put_change(changeset, :id, Ecto.UUID.generate())
      _ -> changeset
    end
  end
end
