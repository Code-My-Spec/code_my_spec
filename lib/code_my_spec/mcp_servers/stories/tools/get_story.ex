defmodule CodeMySpec.McpServers.Stories.Tools.GetStory do
  @moduledoc """
  Gets a single story by ID with full details including acceptance criteria.

  Use list_story_titles to find story IDs if you don't know them.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string, required: true, doc: "Story ID (use list_story_titles to find IDs)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id) do
      {:reply, StoriesMapper.story_get_response(story), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
