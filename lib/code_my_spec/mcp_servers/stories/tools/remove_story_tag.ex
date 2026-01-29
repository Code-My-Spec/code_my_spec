defmodule CodeMySpec.McpServers.Stories.Tools.RemoveStoryTag do
  @moduledoc """
  Removes a tag from a story.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.Tags
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string, required: true, doc: "Story ID to remove tag from"
    field :tag, :string, required: true, doc: "Tag name to remove"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         :ok <- Tags.remove_tag(scope, story, params.tag) do
      {:reply, StoriesMapper.tag_removed_response(story, params.tag), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, :not_found} ->
        {:reply, StoriesMapper.error("Tag '#{params.tag}' not found on this story."), frame}

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
