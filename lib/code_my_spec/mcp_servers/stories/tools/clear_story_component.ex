defmodule CodeMySpec.McpServers.Stories.Tools.ClearStoryComponent do
  @moduledoc """
  Removes the component link from a story.

  Use this when a story is no longer satisfied by its assigned component.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string, required: true, doc: "Story ID to unlink from component"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         {:ok, story} <- Stories.get_story(scope, params.story_id),
         {:ok, updated_story} <- Stories.clear_story_component(scope, story) do
      {:reply, StoriesMapper.story_component_cleared_response(updated_story), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, :not_found} ->
        {:reply, StoriesMapper.error("Story not found"), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
