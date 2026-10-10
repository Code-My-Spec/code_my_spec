defmodule CodeMySpec.Issues.Issue do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Utils.MapAccess

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          title: String.t(),
          severity: :critical | :high | :medium | :low | :info,
          scope: :app | :qa | :docs | :framework,
          description: String.t(),
          status: :incoming | :accepted | :dismissed | :resolved,
          category: :bug | :requirements_change | nil,
          resolution: String.t() | nil,
          source: String.t() | nil,
          story_id: integer() | nil,
          source_path: String.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          assigned_working_copy_id: Ecto.UUID.t() | nil,
          awaiting_role: :coding | :qa | nil,
          synced_from_server: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @severities [:critical, :high, :medium, :low, :info]
  @scopes [:app, :qa, :docs, :framework]
  @statuses [:incoming, :accepted, :dismissed, :resolved]
  @categories [:bug, :requirements_change]

  # `accepted -> dismissed` exists because accepting is a triage decision, and
  # triage decisions are made from a report rather than from the code. Finding
  # out afterwards that an issue is a duplicate, out of scope, or about a
  # surface being retired is ordinary, and it happened twice in one session.
  #
  # Without it the only exit from `accepted` is `resolved`, so withdrawing an
  # issue means writing a resolution for something nobody fixed — a lie in the
  # one field whose entire purpose is to say how it was fixed, and the field a
  # later reader trusts most. Measured 2026-08-20: `358f6c0f` had to be closed
  # that way, with its resolution opening "Nothing was fixed."
  #
  # It costs nothing in the graph. `dismissed` is already terminal and already
  # reachable from `incoming`, and everything that asks whether an issue is
  # still open asks for `incoming ++ accepted` (`AgentTasks.QaApp`), so both
  # exits close it identically. `dismiss_issue` requires a reason, so the
  # withdrawal is always explained — which is more than `resolved` demanded of
  # the same decision.
  @valid_transitions %{
    incoming: [:accepted, :dismissed],
    accepted: [:resolved, :dismissed],
    dismissed: [],
    resolved: []
  }

  @doc "Field descriptions for API documentation."
  def field_docs do
    %{
      title: "Short issue title",
      severity: "Issue severity: critical, high, medium, low, or info",
      description: "Detailed description including steps to reproduce if applicable",
      scope: "Issue scope: app (default), qa, docs, or framework",
      status: "Issue status: incoming, accepted, dismissed, or resolved",
      resolution: "How the issue was resolved or why it was dismissed",
      story_id: "Related story ID, if applicable",
      source_path: "File path where the issue was found, if applicable"
    }
  end

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "issues" do
    field(:title, :string)
    field(:severity, Ecto.Enum, values: @severities)
    field(:scope, Ecto.Enum, values: @scopes, default: :app)
    field(:description, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :incoming)
    field(:category, Ecto.Enum, values: @categories)
    field(:resolution, :string)
    field(:source, :string)
    field(:story_id, :integer)
    belongs_to(:story, CodeMySpec.Stories.Story, define_field: false)
    field(:source_path, :string)
    field(:project_id, :binary_id)
    field(:account_id, :binary_id)

    # The working copy this was raised from. `nil` for issues raised before this
    # existed, and for anything filed through the web UI, which has no checkout.
    field(:working_copy_id, :binary_id)
    # The copy whose team is currently bound to this issue (distinct from
    # `working_copy_id`, which copy raised it). Set by `AssignIssueToWorkingCopy`.
    field(:assigned_working_copy_id, :binary_id)
    # Whose turn it is on an assigned issue (story 1091): the coder's until
    # it submits a fix, QA's until it submits a non-passing attempt, and the
    # coder's again to promote once QA passes it (`:promote`). Read by
    # `Agents.IssueWork` rather than `Agents` reaching into `Qa`'s attempts,
    # which would cycle back (`Qa` already depends on `Agents`).
    field(:awaiting_role, Ecto.Enum, values: [:coding, :qa, :promote])
    # The commit the fix landed on main at, through the promotion queue. An
    # issue resolves once this is set and its QA has passed.
    field(:story_submission_ref, :binary_id)
    field(:story_submission_revision, :string)
    field(:story_submission_evidence, :string)
    field(:story_submitted_at, :utc_datetime_usec)
    field(:story_submission_history, {:array, :map}, default: [])
    field(:landed_commit, :string)
    field(:synced_from_server, :boolean, default: false)
    # A list of attachment maps, e.g. a widget-reported screenshot copied into
    # our S3 bucket: %{"type" => "screenshot", "s3_key" => ..., "content_type" => ...}.
    field(:attachments, {:array, :map}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @castable_fields [
    :title,
    :severity,
    :scope,
    :description,
    :status,
    :category,
    :resolution,
    :source,
    :story_id,
    :source_path,
    :synced_from_server,
    :attachments
  ]

  @doc "Casts and validates the castable fields; does not touch status transitions."
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, @castable_fields)
    |> validate_required([:title, :severity, :description])
    |> unique_constraint([:title, :story_id, :project_id])
  end

  @doc "Changeset for setting or clearing which copy's team this issue is assigned to."
  def assignment_changeset(issue, attrs) do
    cast(issue, attrs, [:assigned_working_copy_id, :awaiting_role])
  end

  @doc "Records the commit the issue's fix landed on main at."
  def landed_changeset(issue, commit) do
    issue
    |> cast(%{landed_commit: commit}, [:landed_commit])
    |> validate_required([:landed_commit])
  end

  @doc "Validates a status transition, requiring a resolution/story link where the new status needs one."
  def status_changeset(issue, attrs) do
    new_status = MapAccess.get(attrs, :status)

    issue
    |> cast(attrs, [:status, :category, :resolution, :story_id])
    |> validate_required([:status])
    |> validate_transition(issue.status, new_status)
    |> maybe_require_resolution(new_status)
    |> maybe_require_story_for_requirements_change()
  end

  @doc "Returns a numeric index for severity ordering (lower = more severe)."
  @spec severity_index(atom()) :: integer()
  def severity_index(:critical), do: 0
  def severity_index(:high), do: 1
  def severity_index(:medium), do: 2
  def severity_index(:low), do: 3
  def severity_index(:info), do: 4

  @doc "Returns the list of severities at or above the given minimum."
  @spec severities_at_or_above(atom()) :: [atom()]
  def severities_at_or_above(min_severity) do
    min_index = severity_index(min_severity)
    Enum.filter(@severities, &(severity_index(&1) <= min_index))
  end

  @doc """
  Whether a task may wait on this issue: open, and at or above `threshold`
  (the project's `fix_issues_min_severity`). Below it nothing offers a fix, so
  a wait would never end.
  """
  @spec blocking?(t(), atom()) :: boolean()
  def blocking?(%__MODULE__{status: status, severity: severity}, threshold),
    do: status in [:incoming, :accepted] and severity in severities_at_or_above(threshold)

  defp validate_transition(changeset, from, to) do
    allowed = Map.get(@valid_transitions, from, [])

    if to in allowed do
      changeset
    else
      add_error(changeset, :status, "cannot transition from #{from} to #{to}")
    end
  end

  defp maybe_require_resolution(changeset, status) when status in [:dismissed, :resolved] do
    validate_required(changeset, [:resolution])
  end

  defp maybe_require_resolution(changeset, _status), do: changeset

  defp maybe_require_story_for_requirements_change(changeset) do
    case get_field(changeset, :category) do
      :requirements_change ->
        case get_field(changeset, :story_id) do
          nil ->
            add_error(
              changeset,
              :story_id,
              "is required when category is :requirements_change"
            )

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end
end
