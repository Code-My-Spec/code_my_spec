defmodule CodeMySpec.Components.Dependency do
  @moduledoc """
  Ecto schema for Dependency entities representing relationships between
  Elixir components within project architecture.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Components.Component

  @type t :: %__MODULE__{
          id: integer() | nil,
          source_component_id: Ecto.UUID.t(),
          target_component_id: Ecto.UUID.t(),
          source_component: Component.t() | Ecto.Association.NotLoaded.t(),
          target_component: Component.t() | Ecto.Association.NotLoaded.t(),
          in_code: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "dependencies" do
    belongs_to :source_component, Component, type: :binary_id
    belongs_to :target_component, Component, type: :binary_id

    # `:authored` when an agent added it with `add_dependency`. A spec file's
    # `## Dependencies` never removes an authored edge (3aeb66cf).
    field :provenance, Ecto.Enum, values: [:authored, :discovered]

    # Whether scanned source has a call or struct use across contexts.
    # Independent of `provenance`: the unique constraint on the
    # pair means one row per edge, so a planned-and-coded edge is
    # `provenance: :authored, in_code: true` rather than two rows.
    field :in_code, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a dependency with validation rules.
  """
  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [:source_component_id, :target_component_id, :provenance, :in_code])
    |> validate_required([:source_component_id, :target_component_id])
    |> validate_no_self_dependency()
    |> unique_constraint([:source_component_id, :target_component_id])
    |> foreign_key_constraint(:source_component_id)
    |> foreign_key_constraint(:target_component_id)
  end

  @spec validate_no_self_dependency(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_no_self_dependency(changeset) do
    source_id = get_field(changeset, :source_component_id)
    target_id = get_field(changeset, :target_component_id)

    case {source_id, target_id} do
      {id, id} when not is_nil(id) ->
        add_error(changeset, :target_component_id, "cannot depend on itself")

      _ ->
        changeset
    end
  end
end
