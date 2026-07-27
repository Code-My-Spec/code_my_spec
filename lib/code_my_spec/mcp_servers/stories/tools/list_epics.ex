defmodule CodeMySpec.McpServers.Stories.Tools.ListEpics do
  @moduledoc """
  Lists the active project's epics with their story counts and how many of
  each epic's stories are released for development.

  This is a backlog tool — it reaches stories the development graph hides.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        {:reply, render(Epics.list_epics(scope)), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
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
