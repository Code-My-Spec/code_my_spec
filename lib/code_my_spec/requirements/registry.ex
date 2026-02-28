defmodule CodeMySpec.Requirements.Registry do
  @moduledoc """
  Unified lookup for requirement definitions across all entity types
  (component, story, project).

  Components.Registry stays as-is for component-type metadata
  (display_name, icon, color, document_type). This module becomes the
  single entry point for requirement definitions.
  """

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Stories.Story

  @spec get_requirements_for_type(String.t()) :: [RequirementDefinition.t()]
  defdelegate get_requirements_for_type(component_type), to: ComponentRegistry

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
