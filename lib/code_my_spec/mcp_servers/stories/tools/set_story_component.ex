defmodule CodeMySpec.McpServers.Stories.Tools.SetStoryComponent do
  @moduledoc """
  Links a story to a component that implements it.

  Use this to track which component satisfies which user story.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string, required: true, doc: "Story ID (use list_story_titles to find)"
    field :component_id, :string, required: true, doc: "Component ID to link"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         {:ok, updated_story} <- Stories.set_story_component(scope, story, params.component_id) do
      {:reply, StoriesMapper.story_component_set_response(updated_story), frame}
    else
      nil ->
        {:reply, StoriesMapper.error("Story not found"), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, :not_found} ->
        {:reply, StoriesMapper.error("Story not found"), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
