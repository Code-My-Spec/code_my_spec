defmodule CodeMySpecWeb.HarnessChannel do
  @moduledoc """
  The **user-plane** side of the background-agent harness. The local app's
  `CodeMySpec.AgentHarness.HarnessProxySocket` joins `harness:<account_id>` (authed
  as the account, like `IssuesChannel`) and bridges the two planes:

    * **Up** — an `agent_message` relayed from a lane is persisted onto the
      session's conversation (`Conversations.add_agent_message/4`) and rendered in
      the operator inbox. The first message for a session subscribes this channel
      to that conversation's topic.
    * **Down** — when the operator replies in the inbox, the reply lands on the
      conversation topic; we push it to the harness as `user_message` (tagged with
      the session's `external_id`), and the proxy routes it to a lane.
  """

  use CodeMySpecWeb, :channel

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message

  @impl true
  def join("harness:" <> account_id, _payload, socket) do
    scope = socket.assigns[:scope]

    if scope && to_string(scope.active_account_id) == account_id do
      # `externals` maps a subscribed conversation_id -> its session_external_id,
      # so an operator reply can be tagged for the harness without a Repo lookup.
      {:ok, socket |> assign(:account_id, account_id) |> assign(:externals, %{})}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid topic"}}

  # ---- Up: harness transcript -> conversation -------------------------------

  @impl true
  def handle_in(
        "agent_message",
        %{
          "external_id" => ext,
          "project_id" => project_id,
          "role" => role,
          "kind" => kind,
          "text" => text
        },
        socket
      ) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(socket.assigns.account_id, project_id, ext)

    Conversations.add_agent_message(conversation, role, kind, text)
    {:noreply, ensure_subscribed(socket, conversation)}
  end

  # ---- Up: what the harness is actually running -----------------------------

  # The device's own answer to "what is running", which is the only answer that
  # can spend a subscription. It is a projection of Presence on the lane topics
  # — a lane is joined for exactly as long as it is alive — so an agent whose
  # process died is absent from this without anybody having to notice.
  #
  # Replies rather than staying silent, because the harness has no other way to
  # learn that the server disagreed with it, and "reported and ignored" looks
  # identical to "never reported" from the device side.
  def handle_in("agents_running", %{"agents" => agents}, socket) when is_list(agents) do
    {:ok, running} = Agents.record_reported(socket.assigns.scope, agents)

    {:reply,
     {:ok,
      %{
        "running" => Enum.map(running, &%{"id" => &1.id, "working_copy" => &1.working_copy})
      }}, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # ---- Down: operator reply -> harness --------------------------------------

  # Only operator replies go down to the harness; the channel also receives the
  # agent's own messages on the same topic (role :assistant / :tool) — ignore those.
  @impl true
  def handle_info({:new_message, %Message{role: :operator} = message}, socket) do
    case Map.get(socket.assigns.externals, message.conversation_id) do
      nil ->
        :ok

      ext ->
        push(socket, "user_message", %{"external_id" => ext, "text" => Message.text(message)})
    end

    {:noreply, socket}
  end

  def handle_info({:new_message, _message}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---- Helpers --------------------------------------------------------------

  defp ensure_subscribed(socket, %Conversation{id: id} = conversation) do
    if Map.has_key?(socket.assigns.externals, id) do
      socket
    else
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, Conversations.conversation_topic(id))

      assign(
        socket,
        :externals,
        Map.put(socket.assigns.externals, id, conversation.session_external_id)
      )
    end
  end
end
