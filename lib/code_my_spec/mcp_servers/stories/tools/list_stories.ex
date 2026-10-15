defmodule CodeMySpec.McpServers.Stories.Tools.ListStories do
  @moduledoc """
  Lists stories in a project with pagination.

  Returns full story details including criteria. For a lightweight
  list of just titles, use list_story_titles instead.
  """

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  @default_limit 20
  @max_limit 100

  schema do
    field :limit, :integer, description: "Max stories to return (default: 20, max: 100)"
    field :offset, :integer, description: "Stories to skip for pagination (default: 0)"
    field :search, :string, description: "Filter by title or description (case-insensitive)"
    field :tag, :string, description: "Filter by tag name"

    field :ready_for_dev, :boolean,
      description:
        "Filter by readiness. Pass false to see the parked backlog — the " <>
          "stories the development graph hides (optional)"

    field :without_epic, :boolean,
      description:
        "Pass true to see only stories not yet assigned to any epic — " <>
          "useful when grouping stories into epics (optional)"

    # The other half of `without_epic`, which shipped alone. You could ask which
    # stories belong to *no* epic and not which belong to *this* one, so
    # "what is in this epic" had no answer short of `get_story` per story —
    # `list_epics` gives a count and not the members. The main agent answered it
    # for the product role three times, each time smoothly, which is how a gap
    # this ordinary stayed invisible (cf035b50).
    field :epic, :string,
      description:
        "Filter to one epic, by slug or id as printed by list_epics — the " <>
          "stories that epic contains (optional)"
  end

  @impl true
  def execute(params, frame) do
    case stories(params, frame) do
      {:ok, {stories, total, limit, offset}} ->
        {:reply, StoriesMapper.stories_list_response(stories, total, limit, offset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(params, frame) do
    with {:ok, {stories, total, limit, offset}} <- stories(params, frame) do
      {:ok, %{"stories" => Enum.map(stories, &row/1), "total" => total, "limit" => limit, "offset" => offset}}
    end
  end

  # Lifted out of `execute/2` so both paths run the same query.
  defp stories(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      limit = (params[:limit] || @default_limit) |> max(0) |> min(@max_limit)
      offset = max(params[:offset] || 0, 0)
      opts = build_opts(params, limit, offset)
      {stories, total} = Stories.list_project_stories_paginated(scope, opts)
      {:ok, {stories, total, limit, offset}}
    end
  end

  # String keys and plain values: these cross into a Lua VM, where an atom key
  # and a struct are not things that exist.
  defp row(story) do
    %{
      "number" => story.number,
      "title" => story.title,
      "story" => story.story || story.description,
      "description" => story.description,
      "ready_for_dev" => story.ready_for_dev == true,
      "epic_id" => story.epic_id,
      "component_id" => story.component_id,
      "priority" => story.priority
    }
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
