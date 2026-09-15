defmodule CodeMySpec.Requirements.Node do
  @moduledoc """
  The persisted half of a requirement node.

  `Requirements.Requirement` is the computed struct and stays that way — this is
  the row it lands in, so edges have something with a primary key to point at.

  ## Why this is thin

  Of the seventeen fields on the computed struct, exactly two are computed:
  `satisfied` and `details`. Every other one is read off the `RequirementDefinition`
  by name (`description`, `scope`, `execution_type`, `validation_type`,
  `orchestrated_by`, `role`, `satisfied_by`, `render_command_always?`)
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

    # What this requirement's own sources looked like when its answer was last
    # worked out. `nil` on a row computed before this existed, which reads as
    # "no basis to skip it" rather than as "unchanged".
    field :inputs_fingerprint, :string

    # Which definition produced this node. The name alone is ambiguous: six of
    # them exist both as a parent template's `:child` def and as the child
    # type's own `:self` def, and the two differ in `orchestrated_by` — which is
    # what groups an orchestrated wave under its context header.
    #
    # `nil` on a row written before these columns existed; `Projection` infers
    # for those and the next pass rewrites them.
    field :owner_component_type, :string
    field :node_scope, :string

    belongs_to :component, Component, type: :binary_id
    belongs_to :story, Story
    belongs_to :project, Project, type: :binary_id

    # Which checkout reached this verdict.
    #
    # Not an owner — the owner is still exactly one of the three above. This is
    # the *vantage point*: `Preloader.load/1` scopes its file query to one
    # working copy, so `satisfied` has only ever been a statement about what one
    # checkout could see. Storing it without saying whose view it was meant
    # every checkout that synced overwrote the project's whole graph.
    #
    # Nullable, and the null means something: the UI path computes with no
    # working copy on purpose, blending every checkout's files. That row is the
    # project-wide answer, and the unique indexes use `NULLS NOT DISTINCT` so
    # there is exactly one of it rather than a fresh duplicate per render.
    belongs_to :working_copy, CodeMySpec.WorkingCopies.WorkingCopy, type: :binary_id

    timestamps()
  end

  @cast_fields [
    :name,
    :description,
    :satisfied,
    :details,
    :checked_at,
    :inputs_fingerprint,
    :owner_component_type,
    :node_scope,
    :component_id,
    :story_id,
    :project_id,
    :working_copy_id
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
  #
  # `working_copy_id` is deliberately not counted here. It is not an owner and
  # never makes a node reachable — it says whose view produced the verdict, and
  # every one of the three owners can carry one.
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
