defmodule CodeMySpecTest.MailboxWire do
  @moduledoc false
  use Boundary, top_level?: true, deps: [CmsHarness, CodeMySpecWeb], exports: :all
  alias CodeMySpecWeb.HarnessProjectChannel

  # Real engine + both channel handlers + database. Only the websocket bytes
  # are replaced, so startup and consumption must perform their real roundtrip.
  defmodule Channel do
    @moduledoc false
    use GenServer
    alias CmsHarness.Project.ChannelClient, as: Client
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init({root, scope}) do
      Registry.register(CmsHarness.Registry, {:channel, root}, nil)
      Process.put({CmsHarness.Project.Transport, :impl}, CmsHarness.Project.Transport.Test)
      Process.put({CmsHarness.Project.Transport.Test, :owner}, self())

      socket = %Slipstream.Socket{
        assigns: %{
          joined: true,
          pending: %{},
          analysis_refs: %{},
          topic: "harness_project:#{scope.active_project_id}",
          project: %{root: root}
        }
      }

      {:ok, %{socket: socket, scope: scope, awaiting: %{}}}
    end

    def handle_call({:launch, request}, from, state) do
      request = Map.put(request, "ref", "launch")

      {:ok, socket} =
        Client.handle_message(state.socket.assigns.topic, "start_agent", request, state.socket)

      {:noreply, %{state | socket: socket, awaiting: Map.put(state.awaiting, "launch", from)}}
    end

    def handle_call({:deliver, request}, from, state) do
      {:ok, socket} =
        Client.handle_message(
          state.socket.assigns.topic,
          "mailbox_delivery",
          request,
          state.socket
        )

      {:noreply,
       %{state | socket: socket, awaiting: Map.put(state.awaiting, request["ref"], from)}}
    end

    def handle_call({:mailbox, _} = request, from, state) do
      case Client.handle_call(request, from, state.socket) do
        {:noreply, socket} -> {:noreply, %{state | socket: socket}}
        {:reply, reply, socket} -> {:reply, reply, %{state | socket: socket}}
      end
    end

    def handle_info({:transport_push, _, "agent_mailbox", params, ref}, state) do
      {:reply, reply, _} =
        HarnessProjectChannel.handle_in("agent_mailbox", params, %Phoenix.Socket{
          assigns: %{scope: state.scope}
        })

      {:ok, socket} = Client.handle_reply(ref, reply, state.socket)
      {:noreply, %{state | socket: socket}}
    end

    def handle_info({:transport_push, _, event, payload, _}, state)
        when event in ["agent_start_result", "agent_send_result"] do
      {from, awaiting} = Map.pop(state.awaiting, payload["ref"])
      GenServer.reply(from, payload)
      {:noreply, %{state | awaiting: awaiting}}
    end

    def handle_info(event, state) do
      {:noreply, socket} = Client.handle_info(event, state.socket)
      {:noreply, %{state | socket: socket}}
    end
  end

  defmodule Transport do
    @moduledoc false
    def dispatch_message(_copy, agent, ref, text, _timeout) do
      [{wire, _}] = Registry.lookup(CmsHarness.Registry, {:channel, agent.working_copy})

      case GenServer.call(
             wire,
             {:deliver,
              %{"ref" => ref, "message_ref" => ref, "agent_id" => agent.id, "message" => text}},
             5_000
           ) do
        %{"status" => "ok", "disposition" => "started"} -> {:ok, :started}
        %{"reason" => "busy"} -> {:error, :busy}
        other -> {:error, other}
      end
    end
  end
end
