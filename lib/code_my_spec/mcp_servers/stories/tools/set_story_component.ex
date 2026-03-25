defmodule CodeMySpec.McpServers.Stories.Tools.SetStoryComponent do
  @moduledoc """
  Links a story to the component that implements it, by module name.

  Use this to track which component satisfies which user story.
  Find module names with the list components tool or architecture docs.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string, required: true, doc: "Story ID (use list_story_titles to find)"
    field :module_name, :string, required: true, doc: "Component module name, e.g. \"MyApp.Accounts\""
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         component when not is_nil(component) <-
           Components.get_component_by_module_name(scope, params.module_name),
         {:ok, updated_story} <- Stories.set_story_component(scope, story, component.id) do
      {:reply, StoriesMapper.story_component_set_response(updated_story), frame}
    else
      nil ->
        {:reply, StoriesMapper.error("Story or component not found"), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
