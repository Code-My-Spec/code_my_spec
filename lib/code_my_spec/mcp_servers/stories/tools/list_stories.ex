defmodule CodeMySpec.McpServers.Stories.Tools.ListStories do
  @moduledoc """
  Lists stories in a project with pagination.

  Returns full story details including criteria. For a lightweight
  list of just titles, use list_story_titles instead.
  """

  use Anubis.Server.Component, type: :tool

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

    field :ready_for_dev, :boolean,
      doc:
        "Filter by readiness. Pass false to see the parked backlog — the " <>
          "stories the development graph hides (optional)"

    field :without_epic, :boolean,
      doc:
        "Pass true to see only stories not yet assigned to any epic — " <>
          "useful when grouping stories into epics (optional)"

    # The other half of `without_epic`, which shipped alone. You could ask which
    # stories belong to *no* epic and not which belong to *this* one, so
    # "what is in this epic" had no answer short of `get_story` per story —
    # `list_epics` gives a count and not the members. The main agent answered it
    # for the product role three times, each time smoothly, which is how a gap
    # this ordinary stayed invisible (cf035b50).
    field :epic, :string,
      doc:
        "Filter to one epic, by slug or id as printed by list_epics — the " <>
          "stories that epic contains (optional)"
  end

  @impl true
  def execute(params, frame) do
    Logger.debug(
      "[ListStories] execute called, scope project: #{inspect(frame.assigns[:current_scope] && frame.assigns[:current_scope].active_project_id)}"
    )

    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        limit = (params[:limit] || @default_limit) |> max(0) |> min(@max_limit)
        offset = max(params[:offset] || 0, 0)
        opts = build_opts(params, limit, offset)

        Logger.debug(
          "[ListStories] calling list_project_stories_paginated with project_id: #{scope.active_project_id}"
        )

        {stories, total} = Stories.list_project_stories_paginated(scope, opts)
        Logger.debug("[ListStories] got #{total} stories, page size: #{length(stories)}")
        {:reply, StoriesMapper.stories_list_response(stories, total, limit, offset), frame}

      {:error, atom} ->
        Logger.warning("[ListStories] validation failed: #{inspect(atom)}")
        {:reply, StoriesMapper.error(atom), frame}
    end
  end

  defp build_opts(params, limit, offset) do
    opts = [limit: limit, offset: offset]
    opts = if params[:search], do: Keyword.put(opts, :search, params[:search]), else: opts
    opts = if params[:tag], do: Keyword.put(opts, :tag, params[:tag]), else: opts

    opts =
      if is_boolean(params[:ready_for_dev]),
        do: Keyword.put(opts, :ready_for_dev, params[:ready_for_dev]),
        else: opts

    opts =
      if is_boolean(params[:without_epic]),
        do: Keyword.put(opts, :without_epic, params[:without_epic]),
        else: opts

    if params[:epic], do: Keyword.put(opts, :epic_id, params[:epic]), else: opts
  end
end
