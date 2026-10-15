defmodule CodeMySpec.McpServers.Stories.Tools.SetActiveStory do
  @moduledoc """
  Select the story the team on the current working copy works on.

  Whoever calls it — a team member, the main agent, a session — the story goes
  to the whole team, the copy's coding and QA agents, who see it through
  together (a31f1cd6, `Agents.assign_team/3`).

  The main agent steers a feature copy's team by naming it with
  `working_copy_id`; anyone else selects for their own copy only. The main copy
  itself is never given a story: work is promoted to it, not done on it.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  schema do
    field :story_number, :integer,
      description:
        "Number of the story for this copy's team to work on. It must be ready for " <>
          "development and not assigned to another copy. Every coding and QA agent on the " <>
          "copy takes it; the story they held before is released. Omit to clear it."

    field :working_copy_id, :string,
      description:
        "Id of the feature copy whose team takes the story, from list_working_copies. Only " <>
          "the main agent may name another copy; everyone else selects for their own."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, copy_id} <- target(scope, frame, Map.get(params, :working_copy_id)),
         {:ok, story_id} <- story_id(scope, Map.get(params, :story_number)),
         {:ok, assigned} <- Agents.assign_team(scope, copy_id, story_id) do
      {:reply, Response.text(Response.tool(), message(assigned, params)), frame}
    else
      {:error, :story_assigned_elsewhere} ->
        {:reply, Response.error(Response.tool(), held_elsewhere(scope_of(frame), params)), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), error_message(reason)), frame}
    end
  end

  # Which copy holds it, and how to free it. The refusal named neither, so main
  # handed story 1046 to team 2, was refused, and asked John which copy held it
  # because its tools did not say (2026-10-12).
  defp held_elsewhere(scope, %{story_number: number}) do
    with %{working_copy_id: copy_id} when is_binary(copy_id) <-
           Stories.get_story_by_number(scope, number),
         {:ok, copy} <- WorkingCopies.fetch(copy_id) do
      "Story #{number} is assigned to working copy #{copy.label || copy_id} (#{copy_id}). " <>
        "Free it with unassign_story_from_working_copy, then select it again."
    else
      _ -> error_message(:story_assigned_elsewhere)
    end
  end

  defp scope_of(frame) do
    {:ok, scope} = Validators.validate_local_scope(frame)
    scope
  end

  defp message(nil, _params),
    do:
      "This copy's team has no story selected, and the story it held is free for another " <>
        "copy to take."

  defp message(_id, params),
    do: "Story #{params.story_number} is the story of every coding and QA agent on this copy."

  # The caller's own copy unless it names one; naming another is the main
  # agent's alone.
  defp target(scope, _frame, nil), do: {:ok, scope.active_working_copy_id}
  defp target(%{active_working_copy_id: own}, _frame, own), do: {:ok, own}

  defp target(scope, frame, copy_id) do
    if main_agent?(scope, frame), do: {:ok, copy_id}, else: {:error, :not_your_copy}
  end

  defp main_agent?(scope, frame) do
    with agent_id when is_binary(agent_id) <- frame.assigns[:agent_id],
         {:ok, agent} <- Agents.fetch_agent(scope, agent_id) do
      RoleProfile.scope(agent.role) == :project
    else
      _ -> false
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

  defp error_message(:no_team),
    do:
      "No coding or QA agent is on this working copy, so there is no team to give the story " <>
        "to. Staff the copy first."

  defp error_message(:main_copy),
    do:
      "Story work happens on feature copies; the main copy is promoted to, not worked on. " <>
        "Name a feature copy with working_copy_id."

  defp error_message(:not_your_copy),
    do: "Only the main agent selects a story for another working copy; select for your own."

  defp error_message(:not_found), do: "No eligible story or working copy exists in this project."
  defp error_message(:story_not_ready), do: "The story must be ready for development first."

  defp error_message(:story_done),
    do:
      "That story is already promoted and every requirement of it is satisfied on this copy, " <>
        "so there is nothing left for a team to do on it. Pick another story."

  defp error_message(:story_assigned_elsewhere),
    do: "The story is assigned to another working copy. Reassign it explicitly first."

  defp error_message(reason), do: "Could not select the active story: #{inspect(reason)}"
end
