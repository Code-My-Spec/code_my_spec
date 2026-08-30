defmodule CodeMySpec.McpServers.Stories.Tools.ListStoryTitles do
  @moduledoc """
  Lists story titles in a project (lightweight).

  Returns just ID, title, and component_id - no criteria or full descriptions.
  Use this for quick lookups, selection lists, or when you need to find a story ID.

  From a script this answers with records rather than the listing, so the
  titles can be filtered and counted without parsing prose.
  """

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :search, :string, doc: "Filter by title (case-insensitive)"
  end

  @impl true
  def execute(params, frame) do
    case titles(params, frame) do
      {:ok, titles} -> {:reply, StoriesMapper.story_titles_response(titles), frame}
      {:error, atom} -> {:reply, StoriesMapper.error(atom), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(params, frame) do
    with {:ok, titles} <- titles(params, frame) do
      {:ok, Enum.map(titles, &row/1)}
    end
  end

  # Lifted out of `execute/2` so both paths run the same query. A second
  # implementation for scripts is a second thing to keep true.
  defp titles(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      opts = if params[:search], do: [search: params[:search]], else: []
      {:ok, Stories.list_story_titles(scope, opts)}
    end
  end

  # String keys and plain values: these cross into a Lua VM, where an atom key
  # and a struct are not things that exist.
  defp row(title) do
    %{
      "id" => title.id,
      "title" => title.title,
      "component_id" => title.component_id
    }
  end
end
