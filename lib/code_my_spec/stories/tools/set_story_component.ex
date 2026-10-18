defmodule CodeMySpec.Stories.Tools.SetStoryComponent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "set_story_component"

  @impl true
  def description do
    """
    Links a story to the component that implements it, by module name.
    """
  end

  @impl true
  def params do
    %{
      module_name:
        {:required,
         {:meta, :string, [description: "Component module name, e.g. \"MyApp.Accounts\""]}},
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        do_set_component(params, scope, context)

      {:error, reason} ->
        StoriesMapper.error(reason)
    end
  end

  defp do_set_component(params, scope, _context) do
    with component when not is_nil(component) <-
           Components.get_component_by_module_name(scope, params.module_name),
         story when not is_nil(story) <-
           Stories.get_story_by_number(scope, params.story_number),
         {:ok, updated} <-
           Stories.set_story_component(scope, story, component.id) do
      StoriesMapper.story_component_set_response(updated)
    else
      nil ->
        StoriesMapper.error("Component or story not found: #{params.module_name}")

      {:error, reason} ->
        StoriesMapper.error(reason)
    end
  end
end
