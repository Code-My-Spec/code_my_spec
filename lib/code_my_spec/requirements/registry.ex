defmodule CodeMySpec.Requirements.Registry do
  @moduledoc """
  Unified lookup for requirement definitions across all entity types
  (component, story, project).

  `Components.Registry` keeps component-type *metadata* — display name, icon,
  colour, document type, dependency order. That table is a fact about what a
  component is, needs no database, and now lives in `cms_scan` so the light
  harness classifies files exactly as the server does.

  Everything that reads `RequirementDefinitionData` lives here instead. It used
  to live on `Components.Registry` too, which meant that module straddled the
  line: a library holding the type table would have had to call back into the
  application that consumes it, and a library calling its consumer fails at
  runtime the first time anyone uses it standalone. Splitting on "does this need
  the requirement definitions" puts each half where it can actually resolve.
  """

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Stories.Story

  @doc "The full graph template for a component type."
  @spec get_graph_template(String.t()) :: [RequirementDefinition.t()]
  def get_graph_template(component_type),
    do: RequirementDefinitionData.graph_for_type(component_type)

  @doc """
  Requirement definitions for a component type.

  For types with parent/child graphs this returns every definition in the
  template; the graph instantiation code does the parent/child scoping.
  """
  @spec get_requirements_for_type(String.t()) :: [RequirementDefinition.t()]
  def get_requirements_for_type(component_type),
    do: RequirementDefinitionData.graph_for_type(component_type)

  @doc """
  True iff this type's graph template defines child-scoped requirements — i.e.
  it can have child components nested under it.

  Derived from the template rather than hardcoded, so it stays correct as
  templates evolve.
  """
  @spec has_children?(String.t()) :: boolean()
  def has_children?(component_type) do
    component_type
    |> get_graph_template()
    |> Enum.any?(&(&1.node_scope == :child))
  end

  @spec get_story_requirements() :: [RequirementDefinition.t()]
  def get_story_requirements, do: RequirementDefinitionData.story_requirements()

  @spec get_project_requirements() :: [RequirementDefinition.t()]
  def get_project_requirements, do: RequirementDefinitionData.project_requirements()

  @doc """
  Unified lookup by entity struct. Returns the requirement definitions
  applicable to the given entity.
  """
  @spec get_requirements(Component.t() | Story.t() | Project.t()) :: [RequirementDefinition.t()]
  def get_requirements(%Component{type: type}), do: get_requirements_for_type(type)
  def get_requirements(%Story{}), do: get_story_requirements()
  def get_requirements(%Project{}), do: get_project_requirements()
end
