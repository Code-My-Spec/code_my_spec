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
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Sessions
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

  @doc """
  Every intervention that happened while one of this story's tasks was
  open on the agent it was open on.
  """
  @spec story(Scope.t(), Story.t()) :: [intervention()]
  def story(%Scope{} = scope, %Story{} = story) do
    scope
    |> Sessions.list_tasks_for_story(story.id)
    |> Enum.filter(& &1.agent_id)
    |> Enum.group_by(& &1.agent_id)
    |> Enum.flat_map(fn {agent_id, tasks} ->
      scope |> for_agent(agent_id) |> Enum.filter(&within_any?(&1, tasks))
    end)
  end

  defp within_any?(intervention, tasks), do: Enum.any?(tasks, &within?(intervention, &1))

  defp within?(_intervention, %{started_at: nil}), do: false

  defp within?(%{at: at}, task) do
    ended = task.completed_at || DateTime.utc_now()
    DateTime.compare(at, task.started_at) != :lt and DateTime.compare(at, ended) != :gt
  end

  @doc """
  Interventions on agents holding no story right now -- the project-level
  case criterion 1998 describes, for a restart made while no team was
  holding anything.

  Approximate: an agent's *current* `story_id` is all the record keeps, so
  an intervention that happened while this agent briefly held no story,
  before or after holding one, cannot be told apart from one made before
  it ever took a story at all. Both are project-level, which is the
  distinction this criterion actually asks for.
  """
  @spec project_level(Scope.t()) :: [intervention()]
  def project_level(%Scope{} = scope) do
    scope
    |> Agents.list_agents()
    |> Enum.filter(&is_nil(&1.story_id))
    |> Enum.flat_map(&for_agent(scope, &1.id))
  end
end
