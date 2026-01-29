defmodule CodeMySpec.McpServers.Stories.Tools.ListStoriesByTag do
  @moduledoc """
  Lists all stories that have a specific tag.

  Use this to see which stories are grouped under a particular domain or category.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Tags
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :tag, :string, required: true, doc: "Tag name to search for"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      stories = Tags.find_stories_by_tag(scope, params.tag)
      {:reply, StoriesMapper.stories_by_tag_response(stories, params.tag), frame}
    else
      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
