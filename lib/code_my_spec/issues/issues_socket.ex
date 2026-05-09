defmodule CodeMySpec.Issues.IssuesSocket do
  @moduledoc """
  Long-lived Slipstream WebSocket client that connects to the server's
  issues channel and upserts issues into the local database when events arrive.

  Started from `CodeMySpecLocalWeb.SocketSupervisor` per local account, in
  parallel with the initial bulk pull from `Issues.BootSync`. Reconnects
  automatically with a fresh OAuth token on disconnect.
  """

  use Slipstream

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Users.Scope

  def start_link(opts) do
    scope = Keyword.fetch!(opts, :scope)
    Slipstream.start_link(__MODULE__, %{scope: scope}, name: name(scope))
  end

  defp name(%Scope{active_account_id: account_id}) do
    Module.concat(__MODULE__, "Account_#{account_id}")
  end

  @impl Slipstream
  def init(%{scope: scope}) do
    case build_ws_url() do
      {:ok, uri} ->
        socket =
          new_socket()
          |> assign(:scope, scope)
          |> assign(:topic, "issues:#{scope.active_account_id}")
          |> connect!(uri: uri)

        {:ok, socket}

      {:error, reason} ->
        Logger.warning("[IssuesSocket] Cannot connect: #{inspect(reason)}")
        :ignore
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("[IssuesSocket] Connected, joining #{socket.assigns.topic}")
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    Logger.info("[IssuesSocket] Joined #{topic}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "issue_created", payload, socket) do
    Logger.info("[IssuesSocket] Issue created: #{payload["id"]}")
    upsert_from_payload(payload)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "issue_accepted", payload, socket) do
    Logger.info("[IssuesSocket] Issue accepted: #{payload["id"]}")
    upsert_from_payload(payload)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "issue_dismissed", payload, socket) do
    Logger.info("[IssuesSocket] Issue dismissed: #{payload["id"]}")
    upsert_from_payload(payload)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "issue_resolved", payload, socket) do
    Logger.info("[IssuesSocket] Issue resolved: #{payload["id"]}")
    upsert_from_payload(payload)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(topic, event, _payload, socket) do
    Logger.debug("[IssuesSocket] Unhandled message on #{topic}: #{event}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    case build_ws_url() do
      {:ok, uri} ->
        Logger.info("[IssuesSocket] Disconnected (#{inspect(reason)}), reconnecting with fresh token")
        connect(socket, uri: uri)

      {:error, token_error} ->
        Logger.warning("[IssuesSocket] Disconnected (#{inspect(reason)}); cannot refresh token: #{inspect(token_error)}")
        reconnect(socket)
    end
  end

  # -- Private ----------------------------------------------------------------

  defp upsert_from_payload(payload) do
    attrs = %{
      title: payload["title"],
      severity: safe_atom(payload["severity"]),
      scope: safe_atom(payload["scope"]),
      description: payload["description"],
      source: payload["source"],
      status: safe_atom(payload["status"]),
      story_id: payload["story_id"],
      project_id: payload["project_id"],
      account_id: payload["account_id"]
    }

    %Issue{id: payload["id"]}
    |> Issue.changeset(attrs)
    |> Ecto.Changeset.put_change(:project_id, payload["project_id"])
    |> Ecto.Changeset.put_change(:account_id, payload["account_id"])
    |> Ecto.Changeset.put_change(:status, safe_atom(payload["status"]))
    |> CodeMySpec.Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  rescue
    e ->
      Logger.warning("[IssuesSocket] Failed to upsert issue: #{Exception.message(e)}")
  end

  defp safe_atom(nil), do: nil
  defp safe_atom(val) when is_atom(val), do: val
  defp safe_atom(val) when is_binary(val), do: String.to_existing_atom(val)

  defp build_ws_url do
    with {:ok, token} <- OAuthClient.get_token() do
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
