defmodule CodeMySpec.Requirements.Node do
  @moduledoc """
  The persisted half of a requirement node.

  `Requirements.Requirement` is the computed struct and stays that way — this is
  the row it lands in, so edges have something with a primary key to point at.

  ## Why this is thin

  Of the seventeen fields on the computed struct, exactly two are computed:
  `satisfied` and `details`. Every other one is read off the `RequirementDefinition`
  by name (`description`, `scope`, `execution_type`, `validation_type`,
  `orchestrated_by`, `subagent_role`, `satisfied_by`, `render_command_always?`)
  or off the entity (`entity_name`). Persisting those would be storing a second
  copy of the definition table and inviting the two to disagree.

  So a row is identity plus verdict. Everything else rehydrates from the
  registry at read time, which is also what keeps a definition change from
  needing a backfill.

  `description` is the one exception, carried because the column is `NOT NULL`
  and predates this.

  ## Identity

  One of `component_id`, `story_id`, `project_id` is set and the others are
  null — which is what `entity_type` means, so it is not a column. Three partial
  unique indexes on `(<entity>_id, name)` make that identity enforceable, and
  they are the conflict target an upsert needs. The project one had drifted out
  of the database; `20260810000000` put it back.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories.Story

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          description: String.t(),
          satisfied: boolean(),
          details: map(),
          checked_at: NaiveDateTime.t() | nil
        }

  schema "requirements" do
    field :name, :string
    field :description, :string
    field :satisfied, :boolean, default: false
    field :details, :map, default: %{}
    field :checked_at, :naive_datetime

    belongs_to :component, Component, type: :binary_id
    belongs_to :story, Story
    belongs_to :project, Project, type: :binary_id

    timestamps()
  end

  @cast_fields [
    :name,
    :description,
    :satisfied,
    :details,
    :checked_at,
    :component_id,
    :story_id,
    :project_id
  ]

  def changeset(node, attrs) do
    node
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :description])
    |> validate_one_owner()
  end

  # A node belongs to exactly one entity. Two owners would satisfy two different
  # unique indexes and be reachable as two different nodes; none would be
  # reachable as neither.
  defp validate_one_owner(changeset) do
    owners =
      [:component_id, :story_id, :project_id]
      |> Enum.count(&(get_field(changeset, &1) != nil))

    case owners do
      1 -> changeset
      _ -> add_error(changeset, :base, "a requirement belongs to exactly one entity")
    end
  end
end
