defmodule CodeMySpec.AgentHarness.HarnessProxySocket do
  @moduledoc """
  Long-lived Slipstream client that bridges the local harness data plane to the
  server's user plane. One per local account, started from
  `CodeMySpecLocalWeb.SocketSupervisor` alongside `ProjectsSocket`/`IssuesSocket`.

  Bidirectional over one socket:

    * **Up** — subscribes to the account's relay topic
      (`CodeMySpec.AgentHarness.relay_topic/1`); each `agent_message` broadcast by
      a `HarnessChannel` is pushed to the server's `harness:<account_id>` channel,
      which persists it via `Conversations.add_agent_message/4` and renders it in
      the operator inbox.
    * **Down** — a human reply arrives from the server as `user_message`; we route
      it to the interactive lane (or the manager) via
      `CodeMySpec.AgentHarness.route_to_lane/4`.

  Reconnects automatically with a fresh OAuth token, mirroring `IssuesSocket`.
  """

  use Slipstream
  require Logger

  alias CodeMySpec.AgentHarness
  alias CodeMySpec.AgentHarness.WorkSource
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Auth.WebSocketBackoff
  alias CodeMySpec.Users.Scope

  def start_link(opts) do
    scope = Keyword.fetch!(opts, :scope)
    Slipstream.start_link(__MODULE__, %{scope: scope}, name: name(scope))
  end

  defp name(%Scope{active_account_id: account_id}),
    do: Module.concat(__MODULE__, "Account_#{account_id}")

  @impl Slipstream
  def init(%{scope: scope}) do
    # Subscribe before connecting so relay broadcasts aren't missed once joined;
    # pushes are guarded on `:joined` and simply dropped while disconnected.
    AgentHarness.subscribe_relay(scope.active_account_id)

    case build_ws_url() do
      {:ok, uri} ->
        socket =
          new_socket()
          |> assign(:scope, scope)
          |> assign(:topic, "harness:#{scope.active_account_id}")
          |> assign(:joined, false)
          |> connect!(uri: uri)

        {:ok, socket}

      {:error, reason} ->
        Logger.warning("[HarnessProxySocket] Cannot connect: #{inspect(reason)}")
        :ignore
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("[HarnessProxySocket] Connected, joining #{socket.assigns.topic}")
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    Logger.info("[HarnessProxySocket] Joined #{topic}")
    {:ok, socket |> assign(:joined, true) |> assign(:reconnect_attempts, 0)}
  end

  # server -> local: a human reply. Route to the interactive lane (or manager).
  @impl Slipstream
  def handle_message(_topic, "user_message", %{"external_id" => ext} = payload, socket) do
    role = payload["role"] || WorkSource.interactive_role(ext)
    AgentHarness.route_to_lane(ext, role, "user_message", %{"text" => payload["text"]})
    {:ok, socket}
  end

  def handle_message(topic, event, _payload, socket) do
    Logger.debug("[HarnessProxySocket] Unhandled message on #{topic}: #{event}")
    {:ok, socket}
  end

  # local -> server: relay an agent transcript message up. Dropped while
  # disconnected — the server is the render store, not the store of record.
  @impl Slipstream
  def handle_info({:relay_up, event, payload}, socket) do
    if socket.assigns[:joined] do
      push(socket, socket.assigns.topic, event, payload)
    end

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info(:reconnect, socket) do
    case build_ws_url() do
      {:ok, uri} ->
        {:ok, socket} = connect(socket, uri: uri)
        {:noreply, socket}

      {:error, token_error} ->
        attempts = Map.get(socket.assigns, :reconnect_attempts, 0)
        delay = WebSocketBackoff.delay(attempts)

        Logger.warning(
          "[HarnessProxySocket] Cannot refresh token: #{inspect(token_error)}; retrying in #{delay}ms"
        )

        Process.send_after(self(), :reconnect, delay)
        {:noreply, assign(socket, :reconnect_attempts, attempts + 1)}
    end
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    attempts = Map.get(socket.assigns, :reconnect_attempts, 0)
    delay = WebSocketBackoff.delay(attempts)

    Logger.info(
      "[HarnessProxySocket] Disconnected (#{inspect(reason)}), reconnecting in #{delay}ms (attempt #{attempts + 1})"
    )

    Process.send_after(self(), :reconnect, delay)
    {:ok, socket |> assign(:joined, false) |> assign(:reconnect_attempts, attempts + 1)}
  end

  # OAuth when a user is signed in here; otherwise the project's deploy key,
  # which is all a sprite has. UserSocket accepts either.
  defp socket_credential do
    case OAuthClient.get_token() do
      {:ok, token} ->
        {:ok, token}

      _ ->
        case Application.get_env(:code_my_spec, :deploy_key) do
          key when is_binary(key) and key != "" -> {:ok, key}
          _ -> {:error, :not_authenticated}
        end
    end
  end

  defp build_ws_url do
    with {:ok, token} <- socket_credential() do
      server_url = OAuthClient.get_server_url()

      ws_url =
        server_url
        |> String.replace(~r{^https://}, "wss://")
        |> String.replace(~r{^http://}, "ws://")
        |> Kernel.<>("/socket/websocket?token=#{token}&vsn=2.0.0")

      {:ok, ws_url}
    end
  end
end
