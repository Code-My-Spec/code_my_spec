defmodule CodeMySpec.McpServers.Stories.Tools.ListEpics do
  @moduledoc """
  Lists the active project's epics with their story counts and how many of
  each epic's stories are released for development.

  This is a backlog tool — it reaches stories the development graph hides.
  """

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias Anubis.Server.Response
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case epics(frame) do
      {:ok, epics} -> {:reply, render(epics), frame}
      {:error, atom} -> {:reply, StoriesMapper.error(atom), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(_params, frame) do
    with {:ok, epics} <- epics(frame) do
      {:ok, Enum.map(epics, &row/1)}
    end
  end

  defp epics(frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
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
    Response.tool()
    |> Response.text("No epics in this project.")
  end

  defp render(epics) do
    lines =
      Enum.map_join(epics, "\n", fn epic ->
        stories = if Ecto.assoc_loaded?(epic.stories), do: epic.stories, else: []
        ready = Enum.count(stories, &(&1.ready_for_dev == true))

        "- #{epic.name} (slug: #{epic.slug}, ID: #{epic.id}) — " <>
          "#{length(stories)} stories, #{ready} ready for development"
      end)

    Response.tool()
    |> Response.text("#{length(epics)} epics:\n#{lines}")
  end
end
