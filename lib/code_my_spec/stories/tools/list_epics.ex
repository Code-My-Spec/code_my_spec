defmodule CodeMySpec.Stories.Tools.ListEpics do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Epics
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper

  @impl true
  def name, do: "list_epics"

  @impl true
  def description do
    """
    Lists the active project's epics with their story counts and how many of
    each epic's stories are released for development.

    This is a backlog tool — it reaches stories the development graph hides.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case epics(context) do
      {:ok, epics} -> render(epics)
      {:error, atom} -> StoriesMapper.error(atom)
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, epics} <- epics(context) do
      {:ok, Enum.map(epics, &row/1)}
    end
  end

  defp epics(context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      {:ok, Epics.list_epics(scope)}
    end
  end

  defp row(epic) do
    stories = if Ecto.assoc_loaded?(epic.stories), do: epic.stories, else: []

    %{
      "id" => epic.id,
      "name" => epic.name,
      "slug" => epic.slug,
      "status" => to_string(epic.status),
      "story_count" => length(stories),
      "ready_count" => Enum.count(stories, &(&1.ready_for_dev == true))
    }
  end

  defp render([]) do
    {:ok, "No epics in this project."}
  end

  defp render(epics) do
    lines =
      Enum.map_join(epics, "\n", fn epic ->
        stories = if Ecto.assoc_loaded?(epic.stories), do: epic.stories, else: []
        ready = Enum.count(stories, &(&1.ready_for_dev == true))

        "- #{epic.name} (slug: #{epic.slug}, ID: #{epic.id}) — " <>
          "#{length(stories)} stories, #{ready} ready for development"
      end)

    {:ok, "#{length(epics)} epics:\n#{lines}"}
  end
end
