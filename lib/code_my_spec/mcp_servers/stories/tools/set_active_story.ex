defmodule CodeMySpec.McpServers.Stories.Tools.SetActiveStory do
  @moduledoc "Select the story shared by all agents on the current working copy."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  schema do
    field :story_number, :integer,
      description:
        "Number of the story to work on. It must be ready for development and not assigned " <>
          "to another copy. Pointing a copy at a story releases whatever else it held, so a " <>
          "copy carries one story at a time. Omit to clear it and release them all."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, story_id} <- story_id(scope, Map.get(params, :story_number)),
         {:ok, copy} <- WorkingCopies.set_active_story(scope, story_id) do
      message =
        if copy.active_story_id do
          "Story #{params.story_number} is active for every agent on working copy #{copy.id}."
        else
          "Working copy #{copy.id} has no active story, and the stories it held are free " <>
            "for another copy to take."
        end

      {:reply, Response.text(Response.tool(), message), frame}
    else
      {:error, reason} ->
        {:reply, Response.error(Response.tool(), error_message(reason)), frame}
    end
  end

  defp story_id(_scope, nil), do: {:ok, nil}

  defp story_id(scope, number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, :not_found}
      story -> {:ok, story.id}
    end
  end

  defp error_message(:no_working_copy), do: "This session has no working copy."
  defp error_message(:not_found), do: "No eligible story or working copy exists in this project."
  defp error_message(:story_not_ready), do: "The story must be ready for development first."

  defp error_message(:story_assigned_elsewhere),
    do: "The story is assigned to another working copy. Reassign it explicitly first."

  defp error_message(reason), do: "Could not select the active story: #{inspect(reason)}"
end
