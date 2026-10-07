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
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo
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

  @doc """
  The same interventions `for_agent/2` answers, for every one of `agent_ids`,
  in one query rather than one per agent.

  The `for_scope/2` read below asks this: one `find_or_create` plus one
  `list_messages` per agent is what made the performance page cost a query per
  agent on top of a query per story (issue 844907e0 -- 13k queries against 166
  stories, several seconds of the join before issue 5d359bb3's `assign_async`).
  A conversation belongs to an agent, so the messages of all of them are one
  `conversation_messages` read grouped by `agent_id`, which is what
  `conversation_messages` already carries -- no join back through
  `conversations` needed.

  Reading rather than creating: `for_scope/2` narrows over agents that already
  exist, and an agent with no conversation has no interventions to report, so
  the `find_or_create` half of `for_agent/2` was writing rows only to find
  nothing in them.
  """
  @spec for_agents(Scope.t(), [String.t()]) :: %{String.t() => [intervention()]}
  def for_agents(%Scope{} = _scope, []), do: %{}

  def for_agents(%Scope{} = _scope, agent_ids) do
    agent_ids
    |> Conversation.ids_for_agents()
    |> intervention_messages()
  end

  # The conversations of these agents, then those conversations' interventions:
  # two reads that do not join back through `conversations` to reach an id this
  # already has, and the second carries the text of only the few messages this
  # module counts rather than every message of every agent (issue b118c546).
  defp intervention_messages(conversations) do
    conversations
    |> Map.keys()
    |> Message.interventions(limit_per_agent: @large_limit)
    |> Repo.all()
    |> Enum.map(
      &Map.put(&1, :agent_id, Map.fetch!(conversations, &1.conversation_id))
    )
    |> Enum.group_by(& &1.agent_id)
    |> Map.new(fn {agent_id, messages} -> {agent_id, Enum.flat_map(messages, &classify/1)} end)
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
  Interventions across every agent matching `filter` -- every agent in the
  project when `filter` is empty. The chart's narrowing (story 1092
  criteria 2032-2034): a `story_id` or `working_copy_id` picks out the
  agents that count, the same way `story/2` and `project_level/1` each
  pick out their own slice.
  """
  @spec for_scope(Scope.t(), %{
          optional(:story_id) => integer(),
          optional(:working_copy_id) => Ecto.UUID.t(),
          optional(:agent_id) => Ecto.UUID.t()
        }) :: [intervention()]
  def for_scope(%Scope{} = scope, filter \\ %{}) do
    agents =
      scope
      |> Agents.list_agents()
      |> filter_agents(filter)

    messages = for_agents(scope, Enum.map(agents, & &1.id))

    Enum.flat_map(agents, fn agent ->
      messages
      |> Map.get(agent.id, [])
      |> attach(agent)
    end)
  end

  # `for_agent/2` answers the interventions of one agent without saying which
  # agent they belong to -- the caller knew, because it asked for one. The
  # batch above asks once for every agent at a time, so the answer has to carry
  # it, and `for_scope/2` is where the two fields are put back on.
  defp attach(interventions, agent), do: Enum.map(interventions, &Map.put(&1, :agent_id, agent.id))

  # Every narrowing key applies, not just the first whose clause matches: the
  # page offers working copy, story and agent together, and picking an agent
  # after a copy must count the nudges of that agent on that copy, not all of
  # the agent's or all of the copy's.
  defp filter_agents(agents, filter) do
    agents
    |> narrow(&(&1.story_id == &2), :story_id, filter)
    |> narrow(&(&1.id == &2), :agent_id, filter)
    |> narrow(&(&1.working_copy_id == &2), :working_copy_id, filter)
  end

  defp narrow(agents, match?, key, filter) do
    case Map.get(filter, key) do
      nil -> agents
      value -> Enum.filter(agents, &match?.(&1, value))
    end
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
