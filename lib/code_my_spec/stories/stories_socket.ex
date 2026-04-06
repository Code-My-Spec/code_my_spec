defmodule CodeMySpec.Stories.StoriesSocket do
  @moduledoc """
  Long-lived Slipstream WebSocket client that connects to the server's
  stories channel and upserts stories into the local database when events arrive.

  Started from BootSync after initial story sync. Reconnects automatically.
  """

  use Slipstream

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Repo
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
          |> assign(:topic, "stories:#{scope.active_account_id}")
          |> connect!(uri: uri)

        {:ok, socket}

      {:error, reason} ->
        Logger.warning("[StoriesSocket] Cannot connect: #{inspect(reason)}")
        :ignore
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("[StoriesSocket] Connected, joining #{socket.assigns.topic}")
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    Logger.info("[StoriesSocket] Joined #{topic}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "story_created", payload, socket) do
    Logger.info("[StoriesSocket] Story created: #{payload["id"]}")
    upsert_from_payload(payload, socket.assigns.scope)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "story_updated", payload, socket) do
    Logger.info("[StoriesSocket] Story updated: #{payload["id"]}")
    upsert_from_payload(payload, socket.assigns.scope)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "story_deleted", payload, socket) do
    Logger.info("[StoriesSocket] Story deleted: #{payload["id"]}")
    delete_from_payload(payload)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(topic, event, _payload, socket) do
    Logger.debug("[StoriesSocket] Unhandled message on #{topic}: #{event}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    Logger.info("[StoriesSocket] Disconnected, will reconnect")
    {:ok, reconnect(socket)}
  end

  # -- Private ----------------------------------------------------------------

  defp upsert_from_payload(payload, scope) do
    attrs = %{
      title: payload["title"],
      description: payload["description"],
      status: safe_atom(payload["status"]),
      priority: payload["priority"],
      project_id: payload["project_id"] || scope.active_project_id,
      component_id: payload["component_id"],
      account_id: scope.active_account_id
    }

    %Story{id: payload["id"]}
    |> Story.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  rescue
    e ->
      Logger.warning("[StoriesSocket] Failed to upsert story: #{Exception.message(e)}")
  end

  defp delete_from_payload(payload) do
    case Repo.get(Story, payload["id"]) do
      nil -> :ok
      story -> Repo.delete(story)
    end
  rescue
    e ->
      Logger.warning("[StoriesSocket] Failed to delete story: #{Exception.message(e)}")
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
