defmodule CodeMySpec.McpServers.Stories.Tools.ListStories do
  @moduledoc """
  Lists stories in a project with pagination.

  Returns full story details including criteria. For a lightweight
  list of just titles, use list_story_titles instead.
  """

  use Hermes.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

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
    Logger.debug("[ListStories] execute called, scope project: #{inspect(frame.assigns[:current_scope] && frame.assigns[:current_scope].active_project_id)}")
    Logger.debug("[ListStories] stories impl: #{inspect(Application.get_env(:code_my_spec, :stories_implementation, CodeMySpec.Stories.StoriesRepository))}")

    case Validators.validate_scope(frame) do
      {:ok, scope} ->
        limit = min(params[:limit] || @default_limit, @max_limit)
        offset = params[:offset] || 0

        opts = [limit: limit, offset: offset]
        opts = if params[:search], do: Keyword.put(opts, :search, params[:search]), else: opts
        opts = if params[:tag], do: Keyword.put(opts, :tag, params[:tag]), else: opts

        Logger.debug("[ListStories] calling list_project_stories_paginated with project_id: #{scope.active_project_id}")
        {stories, total} = Stories.list_project_stories_paginated(scope, opts)
        Logger.debug("[ListStories] got #{total} stories, page size: #{length(stories)}")
        {:reply, StoriesMapper.stories_list_response(stories, total, limit, offset), frame}

      {:error, atom} ->
        Logger.warning("[ListStories] validation failed: #{inspect(atom)}")
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
