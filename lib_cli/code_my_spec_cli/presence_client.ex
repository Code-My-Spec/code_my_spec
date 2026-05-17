defmodule CodeMySpecCli.PresenceClient do
  @moduledoc """
  Maintains a websocket connection to the CodeMySpec server and joins
  the per-user CLI presence channel (`cli:user:<id>`).

  The dashboard subscribes to that topic via `Phoenix.Presence` to
  drive its connection-status pill. Without this client running, a
  CLI user sees "Not connected" on the dashboard even though `cms`
  is up.

  Started in `CodeMySpecLocalWeb.Application`'s supervisor. If no
  client_user is on file yet (pre-`/codemyspec:authenticate`), retries
  on a slow timer; same on disconnect.
  """

  use Slipstream
  require Logger

  alias CodeMySpec.Auth.OAuthClient

  @retry_unauth_ms 10_000
  @retry_disconnect_ms 5_000

  def start_link(_opts) do
    Slipstream.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl Slipstream
  def init(_args) do
    Logger.info("[Presence.Client] starting")
    send(self(), :try_connect)
    {:ok, new_socket()}
  end

  @impl Slipstream
  def handle_info(:try_connect, socket) do
    case authenticate() do
      {:ok, user_id, ws_url} ->
        Logger.info("[Presence.Client] connecting user_id=#{user_id} url=#{redact(ws_url)}")

        case connect(socket, uri: ws_url) do
          {:ok, configured_socket} ->
            {:noreply, assign(configured_socket, :user_id, user_id)}

          {:error, reason} ->
            Logger.warning("[Presence.Client] connect error: #{inspect(reason)}")
            Process.send_after(self(), :try_connect, @retry_disconnect_ms)
            {:noreply, socket}
        end

      {:error, reason} ->
        Logger.info(
          "[Presence.Client] not authenticated yet (#{inspect(reason)}); retrying in #{@retry_unauth_ms}ms"
        )

        Process.send_after(self(), :try_connect, @retry_unauth_ms)
        {:noreply, socket}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    user_id = socket.assigns.user_id
    Logger.info("[Presence.Client] connected — joining cli:user:#{user_id}")
    {:ok, join(socket, "cli:user:#{user_id}", %{})}
  end

  @impl Slipstream
  def handle_join("cli:user:" <> _, reply, socket) do
    Logger.info(
      "[Presence.Client] joined for user_id=#{socket.assigns.user_id} reply=#{inspect(reply)}"
    )

    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("[Presence.Client] disconnected: #{inspect(reason)}")
    Process.send_after(self(), :try_connect, @retry_disconnect_ms)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning(
      "[Presence.Client] topic_close topic=#{inspect(topic)} reason=#{inspect(reason)}"
    )

    Process.send_after(self(), :try_connect, @retry_disconnect_ms)
    {:ok, socket}
  end

  defp authenticate do
    with {:ok, user} <- OAuthClient.get_active_client_user(),
         {:ok, token} <- OAuthClient.get_token(),
         server_url when is_binary(server_url) <- OAuthClient.get_server_url() do
      {:ok, user.id, build_ws_url(server_url, token)}
    else
      _ -> {:error, :not_authenticated}
    end
  end

  defp build_ws_url(server_url, token) do
    base =
      server_url
      |> String.replace_prefix("https://", "wss://")
      |> String.replace_prefix("http://", "ws://")

    "#{base}/socket/websocket?token=#{URI.encode_www_form(token)}&vsn=2.0.0"
  end

  defp redact(url) do
    String.replace(url, ~r/(token=)[^&]+/, "\\1<redacted>")
  end
end
