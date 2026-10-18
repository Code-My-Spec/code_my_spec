defmodule CodeMySpec.Stories.Tools.ReleaseStoryFromWorkingCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Stories.StoryRefs

  @impl true
  def name, do: "release_story_from_working_copy"

  @impl true
  def description do
    """
    Free a story from whatever working copy holds it, with nowhere new to go
    yet -- the explicit reassign path `set_active_story` names when a story is
    held elsewhere (3f824f74): free it here, then select it on the copy that
    should take it.

    Main agent only, the same restriction `set_active_story` places on naming
    another copy's `working_copy_id` -- this reaches across copies the same
    way.
    """
  end

  @impl true
  def params do
    %{
      force:
        {:meta, :boolean,
         [
           description:
             "Free it even though the copy holding it has it as its team's active story. Without this, that refuses -- the team there may be mid-work on it."
         ]},
      story_number: {:required, {:meta, :integer, [description: "Story to free."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         :ok <- authorize(scope, context),
         {:ok, story_id} <- StoryRefs.story_id(scope, Map.get(params, :story_number)),
         {:ok, story} <-
           Agents.unassign_story(scope, story_id, force: Map.get(params, :force, false)) do
      {:ok, message(story)}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  defp authorize(scope, context) do
    with agent_id when is_binary(agent_id) <- context[:agent_id],
         {:ok, agent} <- Agents.fetch_agent(scope, agent_id),
         :project <- RoleProfile.scope(agent.role) do
      :ok
    else
      _ -> {:error, :not_main_agent}
    end
  end

  defp message(story),
    do: "Story #{story.number} is free. Select it on its new copy with set_active_story."

  defp error_message(:not_main_agent),
    do: "Only the main agent reassigns a story across working copies."

  defp error_message(:story_not_found),
    do: "No such story. list_story_titles shows the story numbers."

  defp error_message(:not_found), do: "No such story."
  defp error_message(:not_assigned), do: "That story is not held by any working copy."

  defp error_message(:story_active_elsewhere),
    do:
      "That story is the active story of the team holding it. Pass force: true to free it " <>
        "anyway, or let that team finish and land it."

  defp error_message(reason), do: "Could not free the story: #{inspect(reason)}"
end
