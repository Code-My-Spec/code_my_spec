defmodule CodeMySpec.Stories.Tools.ListStoryTitles do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "list_story_titles"

  @impl true
  def description do
    """
    Lists story titles in a project (lightweight).

    Returns just number, title, and component_id - no criteria or full descriptions.
    Use this for quick lookups, selection lists, or when you need to find a story number.

    From a script this answers with records rather than the listing, so the
    titles can be filtered and counted without parsing prose.
    """
  end

  @impl true
  def params do
    %{search: {:meta, :string, [description: "Filter by title (case-insensitive)"]}}
  end

  @impl true
  def call(params, context) do
    case titles(params, context) do
      {:ok, titles} -> StoriesMapper.story_titles_response(titles)
      {:error, atom} -> StoriesMapper.error(atom)
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, titles} <- titles(params, context) do
      {:ok, Enum.map(titles, &row/1)}
    end
  end

  # Lifted out of `execute/2` so both paths run the same query. A second
  # implementation for scripts is a second thing to keep true.
  defp titles(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      opts = if params[:search], do: [search: params[:search]], else: []
      {:ok, Stories.list_story_titles(scope, opts)}
    end
  end

  # String keys and plain values: these cross into a Lua VM, where an atom key
  # and a struct are not things that exist.
  defp row(title) do
    %{
      "number" => title.number,
      "title" => title.title,
      "component_id" => title.component_id
    }
  end
end
