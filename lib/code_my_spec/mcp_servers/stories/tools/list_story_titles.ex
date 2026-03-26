defmodule CodeMySpec.McpServers.Stories.Tools.ListStoryTitles do
  @moduledoc """
  Lists story titles in a project (lightweight).

  Returns just ID, title, and component_id - no criteria or full descriptions.
  Use this for quick lookups, selection lists, or when you need to find a story ID.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :search, :string, doc: "Filter by title (case-insensitive)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      opts = if params[:search], do: [search: params[:search]], else: []
      titles = Stories.list_story_titles(scope, opts)
      {:reply, StoriesMapper.story_titles_response(titles), frame}
    else
      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
