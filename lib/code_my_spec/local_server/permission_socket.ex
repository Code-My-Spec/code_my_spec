defmodule CodeMySpec.LocalServer.PermissionSocket do
  @moduledoc """
  Slipstream WebSocket client that connects to the production server's
  permission channel and waits for a decision.

  Started per-request by the local PermissionController. Sends the decision
  back to the caller process as `{:permission_decision, decision}`.
  """

  use Slipstream

  require Logger

  def start_link(opts) do
    caller = Keyword.fetch!(opts, :caller)
    uri = Keyword.fetch!(opts, :uri)
    request_id = Keyword.fetch!(opts, :request_id)

    Slipstream.start_link(__MODULE__, %{
      caller: caller,
      uri: uri,
      request_id: request_id,
      topic: "permission:#{request_id}"
    })
  end

  @impl Slipstream
  def init(state) do
    {:ok, connect!(state, uri: state.uri)}
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("[PermissionSocket] Connected, joining #{socket.assigns.topic}")
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    Logger.info("[PermissionSocket] Joined #{topic}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "decision", %{"decision" => decision}, socket) do
    Logger.info("[PermissionSocket] Received decision: #{decision}")
    send(socket.assigns.caller, {:permission_decision, decision})
    {:stop, :normal, socket}
  end

  @impl Slipstream
  def handle_message(topic, event, payload, socket) do
    Logger.debug("[PermissionSocket] Unhandled message on #{topic}: #{event} #{inspect(payload)}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    Logger.info("[PermissionSocket] Disconnected")
    send(socket.assigns.caller, {:permission_error, :disconnected})
    {:stop, :normal, socket}
  end
end
