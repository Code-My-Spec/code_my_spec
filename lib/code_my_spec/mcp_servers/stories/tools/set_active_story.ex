defmodule CodeMySpec.McpServers.Stories.Tools.SetActiveStory do
  @moduledoc "Select the story shared by all agents on the current working copy."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies

  schema do
    field :story_id, :string,
      description:
        "Story database ID to work on. It must be ready for development and not assigned " <>
          "to another copy. Omit to clear the active story without changing backlog assignments."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, copy} <- WorkingCopies.set_active_story(scope, Map.get(params, :story_id)) do
      message =
        if copy.active_story_id do
          "Story #{copy.active_story_id} is active for every agent on working copy #{copy.id}."
        else
          "Working copy #{copy.id} has no active story. Its backlog assignments are unchanged."
        end

      {:reply, Response.text(Response.tool(), message), frame}
    else
      {:error, reason} ->
        {:reply, Response.error(Response.tool(), error_message(reason)), frame}
    end
  end

  defp error_message(:no_working_copy), do: "This session has no working copy."
  defp error_message(:not_found), do: "No eligible story or working copy exists in this project."
  defp error_message(:story_not_ready), do: "The story must be ready for development first."

  defp error_message(:story_assigned_elsewhere),
    do: "The story is assigned to another working copy. Reassign it explicitly first."

  defp error_message(reason), do: "Could not select the active story: #{inspect(reason)}"
end
