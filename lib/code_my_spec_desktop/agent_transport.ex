defmodule CodeMySpecDesktop.AgentTransport do
  @moduledoc """
  Detached onboarding agent execution in the desktop's own harness.

  The directory is agent-owned scratch space, not a registered working copy.
  Everything else uses the normal engine: supervised provider sessions, durable
  mailbox consumption, conversation events, and authenticated project MCP tools.
  """

  alias CodeMySpecDesktop.AgentTransport.Events
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.{LaunchRequest, Mailbox, Presence}
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Drafts
  alias CodeMySpec.Users.Scope

  def start_agent(_copy_id, agent, _timeout) do
    scope = scope(agent)

    with :ok <- File.mkdir_p(agent.working_copy),
         {:ok, conversation} <-
           Conversations.find_or_create_agent_conversation(
             agent.account_id,
             agent.project_id,
             agent.id
           ),
         {:ok, _copy} <- CmsHarness.Copy.Supervisor.ensure(agent.working_copy),
         {:ok, relay} <- start_relay(agent, conversation.id) do
      request =
        agent
        |> LaunchRequest.for(CodeMySpec.McpServers.ToolRegistry.registry())
        |> Map.put("project_id", agent.project_id)
        |> Map.put("on_register", fn id, generation ->
          with {:ok, _} = registered <- Mailbox.register(scope, id, generation) do
            # Presence owns a monitor of the actual engine, so a crash removes
            # it immediately. Each restarted generation registers itself again.
            Presence.track(self(), Presence.topic(agent.project_id), id, %{})
            registered
          end
        end)
        |> Map.put("on_consume", fn id, ref, generation ->
          Mailbox.consume(scope, id, ref, generation)
        end)
        |> Map.put("on_event", fn id, envelope ->
          GenServer.cast(relay_name(agent.id), {:event, id, envelope})
        end)
        |> Map.put("on_draft", fn _id, envelope ->
          GenServer.cast(relay_name(agent.id), {:draft, envelope})
        end)

      case CmsHarness.Agents.launch(request) do
        {:ok, _} = result ->
          result

        error ->
          GenServer.stop(relay)
          error
      end
    end
  end

  def dispatch_message(_copy_id, agent, ref, text, timeout),
    do: CmsHarness.Agents.send_message(agent.id, ref, text, timeout)

  def request_work_turn(_copy_id, agent, ref, text, timeout),
    do: CmsHarness.Agents.request_work_turn(agent.id, ref, text, timeout)

  def stop_agent(_copy_id, agent, _timeout) do
    result = CmsHarness.Agents.halt(agent.id)

    case GenServer.whereis(relay_name(agent.id)) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end

    result
  end

  def interrupt_turn(_copy_id, agent) do
    case CmsHarness.Agents.interrupt(agent.id) do
      result when result in [:ok, :idle] -> :ok
      error -> error
    end
  end

  defp scope(agent) do
    %Scope{active_account_id: agent.account_id, active_project_id: agent.project_id}
  end

  defp relay_name(id), do: {:via, Registry, {CmsHarness.Registry, {:desktop_agent_events, id}}}

  defp start_relay(agent, conversation_id) do
    spec = %{
      id: Events,
      start: {Events, :start_link, [{agent, conversation_id, relay_name(agent.id)}]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(
           CmsHarness.Copy.Supervisor.agents(agent.working_copy),
           spec
         ) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  defmodule Events do
    @moduledoc false
    use GenServer

    def start_link({agent, conversation_id, name}),
      do: GenServer.start_link(__MODULE__, {agent, conversation_id}, name: name)

    def init({agent, conversation_id}) do
      scope = %Scope{active_account_id: agent.account_id, active_project_id: agent.project_id}
      {:ok, %{agent: agent, scope: scope, conversation_id: conversation_id}}
    end

    # This must not run in the engine: mailbox_ready can synchronously dispatch
    # its next turn back to that engine. The relay also preserves event order.
    def handle_cast({:event, id, envelope}, state) do
      event = CmsHarness.Project.ChannelClient.encode_turn_event(envelope)
      Agents.record_turn_event(state.scope, id, event)
      record_usage(state.scope, state.agent, event)

      if event["kind"] in ~w(message turn_ended turn_failed turn_cut_off),
        do: Drafts.clear(state.conversation_id)

      {:noreply, state}
    end

    def handle_cast({:draft, %{payload: text}}, state) when is_binary(text) do
      Drafts.put(state.conversation_id, (Drafts.get(state.conversation_id) || "") <> text)
      {:noreply, state}
    end

    def handle_cast({:draft, _}, state), do: {:noreply, state}

    defp record_usage(scope, agent, %{"kind" => "turn_ended", "usage" => %{} = usage}) do
      CodeMySpec.AgentPerformance.TokenUsage.record(
        scope,
        agent.id,
        agent.story_id,
        agent.provider,
        %{
          "model" => agent.model,
          "usage" => usage
        }
      )
    end

    defp record_usage(_scope, _agent, _event), do: :ok
  end
end
