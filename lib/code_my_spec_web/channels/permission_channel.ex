defmodule CodeMySpecWeb.PermissionChannel do
  @moduledoc """
  Channel for real-time permission request decisions.

  The local server (CLI) joins `"permission:<id>"` and waits for the
  decision to be pushed when the user approves/denies via the LiveView.
  """
  use CodeMySpecWeb, :channel

  @impl true
  def join("permission:" <> request_id, _payload, socket) do
    user_id = socket.assigns[:user_id]

    if user_id do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "permission_request:#{request_id}")
      {:ok, assign(socket, :request_id, request_id)}
    else
      {:error, %{reason: "not authenticated"}}
    end
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid topic"}}
  end

  @impl true
  def handle_info({:permission_decided, %{id: _id, decision: decision}}, socket) do
    push(socket, "decision", %{decision: decision})
    {:noreply, socket}
  end
end
