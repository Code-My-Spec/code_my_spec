defmodule CodeMySpec.Requirements.Invalidation do
  @moduledoc """
  One writer's claim that one entity's requirements are out of date.

  The row a `GraphInputs` announcement leaves behind, so the claim outlives the
  process that made it. See the migration for why an accumulated dirty set has
  to be durable where a derived one does not.

  ## Identity

  `component_id` and `story_id` mirror `Requirements.Node`: at most one is set,
  and which one is set is what the entity type means. Both null is the third
  case and it is deliberate — a writer that knows something moved and cannot yet
  say which entities it moved. That is the shape the narrowing work exists to
  remove, and it is counted rather than hidden.
  """

  use Ecto.Schema

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories.Story

  @type entity :: {String.t(), term()} | :project

  @type t :: %__MODULE__{
          id: integer() | nil,
          project_id: Ecto.UUID.t(),
          component_id: Ecto.UUID.t() | nil,
          story_id: integer() | nil,
          source: String.t(),
          observation_id: String.t() | nil
        }

  schema "graph_invalidations" do
    field :source, :string
    field :observation_id, :string

    belongs_to :project, Project, type: :binary_id
    belongs_to :component, Component, type: :binary_id
    belongs_to :story, Story

    timestamps(updated_at: false)
  end

  @doc """
  The entity this mark names, in the same `{type, id}` shape
  `RequirementGraph.stale_entities/3` compares against.

  `:project` for a mark that names nothing, so the two cases stay distinguishable
  downstream — a consumer that treated it as "no entities" would silently drop
  every un-narrowed writer, which is the direction that must never be silent.
  """
  @spec entity(t()) :: entity()
  def entity(%__MODULE__{component_id: id}) when not is_nil(id), do: {"component", id}
  def entity(%__MODULE__{story_id: id}) when not is_nil(id), do: {"story", id}
  def entity(%__MODULE__{}), do: :project
end
