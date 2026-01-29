defmodule CodeMySpec.McpServers.Stories.Tools.ListStoryTags do
  @moduledoc """
  Lists all tags assigned to a story.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.Tags
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string, required: true, doc: "Story ID to list tags for"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id) do
      tags = Tags.list_story_tags(scope, story)
      {:reply, StoriesMapper.story_tags_response(story, tags), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
