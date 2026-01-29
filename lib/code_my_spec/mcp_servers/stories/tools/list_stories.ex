defmodule CodeMySpec.McpServers.Stories.Tools.ListStories do
  @moduledoc """
  Lists stories in a project with pagination.

  Returns full story details including criteria. For a lightweight
  list of just titles, use list_story_titles instead.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  @default_limit 20
  @max_limit 100

  schema do
    field :limit, :integer, doc: "Max stories to return (default: 20, max: 100)"
    field :offset, :integer, doc: "Stories to skip for pagination (default: 0)"
    field :search, :string, doc: "Filter by title or description (case-insensitive)"
    field :tag, :string, doc: "Filter by tag name"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      limit = min(params[:limit] || @default_limit, @max_limit)
      offset = params[:offset] || 0

      opts = [limit: limit, offset: offset]
      opts = if params[:search], do: Keyword.put(opts, :search, params[:search]), else: opts
      opts = if params[:tag], do: Keyword.put(opts, :tag, params[:tag]), else: opts

      {stories, total} = Stories.list_project_stories_paginated(scope, opts)
      {:reply, StoriesMapper.stories_list_response(stories, total, limit, offset), frame}
    else
      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
