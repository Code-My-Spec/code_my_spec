defmodule CodeMySpecWeb.SessionChannel do
  @moduledoc """
  Channel for clients to receive updates for a specific session.

  Clients can join the channel for a specific session ID and receive
  real-time session updates via PubSub broadcasts.
  """
  use CodeMySpecWeb, :channel

  @impl true
  def join("session:" <> session_id_str, _payload, socket) do
    # Parse session_id from the topic
    case Integer.parse(session_id_str) do
      {session_id, ""} ->
        # Verify the user has access to this session
        user_id = socket.assigns[:user_id]

        if user_id do
          # Subscribe to updates for this specific session
          Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "session:#{session_id}")

          {:ok, assign(socket, :session_id, session_id)}
        else
          {:error, %{reason: "not authenticated"}}
        end

      _ ->
        {:error, %{reason: "invalid session_id"}}
    end
  end

  @impl true
  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid topic"}}
  end

  @impl true
  def handle_info({:conversation_id_set, payload}, socket) do
    push(socket, "conversation_id_set", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:session_status_changed, payload}, socket) do
    push(socket, "session_status_changed", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:session_updated, payload}, socket) do
    push(socket, "session_updated", payload)
    {:noreply, socket}
  end
end
