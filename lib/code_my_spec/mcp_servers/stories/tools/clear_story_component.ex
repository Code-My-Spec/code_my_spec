defmodule CodeMySpec.McpServers.Stories.Tools.ClearStoryComponent do
  @moduledoc """
  Removes the component link from a story.

  Use this when a story is no longer satisfied by its assigned component.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :story_number, :integer,
      required: true,
      description: "Story number (list_story_titles shows them)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         story when not is_nil(story) <- Stories.get_story_by_number(scope, params.story_number),
         {:ok, updated_story} <- Stories.clear_story_component(scope, story) do
      {:reply, StoriesMapper.story_component_cleared_response(updated_story), frame}
    else
      nil ->
        {:reply, StoriesMapper.error("Story not found"), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
