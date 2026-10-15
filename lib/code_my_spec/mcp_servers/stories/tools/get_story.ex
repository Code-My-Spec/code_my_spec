defmodule CodeMySpec.McpServers.Stories.Tools.GetStory do
  @moduledoc """
  Gets a single story by number with full details including acceptance criteria.

  Use list_story_titles to find story numbers if you don't know them.
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
         story when not is_nil(story) <- Stories.get_story_by_number(scope, params.story_number) do
      {:reply, StoriesMapper.story_get_response(story), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
