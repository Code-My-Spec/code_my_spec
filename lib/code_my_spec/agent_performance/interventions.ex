defmodule CodeMySpec.AgentPerformance.Interventions do
  @moduledoc """
  Manual interventions -- an operator or user nudge, a restart -- counted
  against the story they served, or at project level when no team was
  holding one.

  An intervention is an `:operator`-role conversation message whose
  `sender_id` says a person acted (`"operator"`, from
  `Conversations.record_sent_to_agent/2`) or that a restart was performed
  (`"system:restart"`, from `Conversations.record_restart/2`). Every other
  `sender_id` on an `:operator`-role message is a harness notice -- a turn
  timeout, a halt, a system reminder -- and is not counted here.

  Attributed by the agent's own `story_id` at read time, not by
  reconstructing which story was active when the message landed -- the
  simpler signal, and the one `SetActiveStory` actually writes. An agent
  that has since moved to a different story is attributed there instead;
  nothing durable records which story an agent held in the past.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @large_limit 100_000

  @type intervention :: %{at: DateTime.t(), kind: :nudge | :restart, reason: String.t()}

  @doc "Every intervention recorded on one agent's conversation."
  @spec for_agent(Scope.t(), String.t()) :: [intervention()]
  def for_agent(%Scope{} = scope, agent_id) do
    with {:ok, agent} <- Agents.fetch_agent(scope, agent_id),
         {:ok, conversation} <-
           Conversations.find_or_create_agent_conversation(
             scope.active_account_id,
             scope.active_project_id,
             agent.id
           ) do
      conversation
      |> Conversations.list_messages(limit: @large_limit)
      |> Enum.flat_map(&classify/1)
    else
      _ -> []
    end
  end

  defp classify(%{role: :operator, sender_id: "operator"} = message),
    do: [%{at: message.inserted_at, kind: :nudge, reason: reason_text(message)}]

  defp classify(%{role: :operator, sender_id: "system:restart"} = message),
    do: [%{at: message.inserted_at, kind: :restart, reason: reason_text(message)}]

  defp classify(_message), do: []

  defp reason_text(%{content: parts}) do
    parts
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  @doc "Every intervention on an agent currently holding this story."
  @spec story(Scope.t(), Story.t()) :: [intervention()]
  def story(%Scope{} = scope, %Story{} = story) do
    scope
    |> Agents.list_agents()
    |> Enum.filter(&(&1.story_id == story.id))
    |> Enum.flat_map(&for_agent(scope, &1.id))
  end

  @doc """
  Interventions on agents holding no story right now -- the project-level
  case criterion 1998 describes, for a restart made while no team was
  holding anything.
  """
  @spec project_level(Scope.t()) :: [intervention()]
  def project_level(%Scope{} = scope) do
    agent_interventions =
      scope
      |> Agents.list_agents()
      |> Enum.filter(&is_nil(&1.story_id))
      |> Enum.flat_map(&for_agent(scope, &1.id))

    app_restarts =
      scope
      |> Agents.list_app_restarts_without_story()
      |> Enum.map(&%{at: &1.inserted_at, kind: :restart, reason: &1.reason})

    Enum.sort_by(agent_interventions ++ app_restarts, & &1.at, DateTime)
  end
end
