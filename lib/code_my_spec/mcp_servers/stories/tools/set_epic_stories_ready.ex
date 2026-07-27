defmodule CodeMySpec.McpServers.Stories.Tools.SetEpicStoriesReady do
  @moduledoc """
  Releases (or parks) every story currently in an epic, in one shot.

  This is a **bulk edit of the stories**, not a property of the epic. Stories
  added to the epic afterwards are unaffected and stay parked — the epic
  carries no readiness of its own and nothing cascades later.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :epic_name, :string, required: true, doc: "Epic whose stories to stamp"

    field :ready_for_dev, :boolean,
      required: true,
      doc: "true to release the epic's stories for development, false to park them"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, epic} <- fetch_epic(scope, params.epic_name),
         {:ok, count} <- Epics.set_epic_stories_ready(scope, epic, params.ready_for_dev) do
      verb = if params.ready_for_dev, do: "released for development", else: "parked"

      response =
        Response.tool()
        |> Response.text(
          "#{count} #{noun(count)} in epic \"#{epic.name}\" #{verb}. " <>
            "Stories added to this epic later are unaffected."
        )

      {:reply, response, frame}
    else
      {:error, atom} -> {:reply, StoriesMapper.error(atom), frame}
    end
  end

  defp fetch_epic(scope, name) do
    case Epics.get_epic_by_name(scope, name) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  defp noun(1), do: "story"
  defp noun(_), do: "stories"
end
