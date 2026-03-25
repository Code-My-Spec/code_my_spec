defmodule CodeMySpec.Issues.Issue do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          title: String.t(),
          severity: :critical | :high | :medium | :low | :info,
          scope: :app | :qa | :docs,
          description: String.t(),
          status: :incoming | :accepted | :dismissed | :resolved,
          resolution: String.t() | nil,
          story_id: integer() | nil,
          source_path: String.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @severities [:critical, :high, :medium, :low, :info]
  @scopes [:app, :qa, :docs]
  @statuses [:incoming, :accepted, :dismissed, :resolved]

  @valid_transitions %{
    incoming: [:accepted, :dismissed],
    accepted: [:resolved],
    dismissed: [],
    resolved: []
  }

  @doc "Field descriptions for API documentation."
  def field_docs do
    %{
      title: "Short issue title",
      severity: "Issue severity: critical, high, medium, low, or info",
      description: "Detailed description including steps to reproduce if applicable",
      scope: "Issue scope: app (default), qa, or docs",
      status: "Issue status: incoming, accepted, dismissed, or resolved",
      resolution: "How the issue was resolved or why it was dismissed",
      story_id: "Related story ID, if applicable",
      source_path: "File path where the issue was found, if applicable"
    }
  end

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "issues" do
    field :title, :string
    field :severity, Ecto.Enum, values: @severities
    field :scope, Ecto.Enum, values: @scopes, default: :app
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :incoming
    field :resolution, :string
    field :story_id, :integer
    field :source_path, :string
    field :project_id, :binary_id
    field :account_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :severity, :scope, :description, :status, :resolution, :story_id, :source_path])
    |> validate_required([:title, :severity, :description])
    |> unique_constraint([:title, :story_id, :project_id])
  end

  @doc false
  def status_changeset(issue, attrs) do
    new_status = attrs[:status] || attrs["status"]

    issue
    |> cast(attrs, [:status, :resolution])
    |> validate_required([:status])
    |> validate_transition(issue.status, new_status)
    |> maybe_require_resolution(new_status)
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
end
