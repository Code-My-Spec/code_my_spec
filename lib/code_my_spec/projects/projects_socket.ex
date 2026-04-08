defmodule CodeMySpec.Projects.ProjectsSocket do
  @moduledoc """
  Long-lived Slipstream WebSocket client that connects to the server's
  projects channel and upserts projects into the local database when events arrive.

  Started under the application supervision tree. Reconnects automatically
  on disconnect.
  """

  use Slipstream

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Projects.Project
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
          |> assign(:topic, "projects:#{scope.active_account_id}")
          |> connect!(uri: uri)

        {:ok, socket}

      {:error, reason} ->
        Logger.warning("[ProjectsSocket] Cannot connect: #{inspect(reason)}")
        :ignore
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("[ProjectsSocket] Connected, joining #{socket.assigns.topic}")
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    Logger.info("[ProjectsSocket] Joined #{topic}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "project_created", payload, socket) do
    Logger.info("[ProjectsSocket] Project created: #{payload["id"]}")
    upsert_from_payload(payload, socket.assigns.scope)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "project_updated", payload, socket) do
    Logger.info("[ProjectsSocket] Project updated: #{payload["id"]}")
    upsert_from_payload(payload, socket.assigns.scope)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "project_deleted", payload, socket) do
    Logger.info("[ProjectsSocket] Project deleted: #{payload["id"]}")
    delete_from_payload(payload)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(topic, event, _payload, socket) do
    Logger.debug("[ProjectsSocket] Unhandled message on #{topic}: #{event}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    Logger.info("[ProjectsSocket] Disconnected, will reconnect")
    {:ok, reconnect(socket)}
  end

  # -- Private ----------------------------------------------------------------

  defp upsert_from_payload(payload, scope) do
    attrs = %{
      id: payload["id"],
      name: payload["name"],
      description: payload["description"],
      module_name: payload["module_name"],
      status: safe_atom(payload["status"]),
      require_specs: payload["require_specs"],
      require_unit_tests: payload["require_unit_tests"],
      account_id: scope.active_account_id
    }

    %Project{id: payload["id"]}
    |> Project.bootstrap_changeset(attrs)
    |> CodeMySpec.Repo.insert(
      on_conflict: {:replace_all_except, [:id, :local_path, :inserted_at]},
      conflict_target: :id
    )
  rescue
    e ->
      Logger.warning("[ProjectsSocket] Failed to upsert project: #{Exception.message(e)}")
  end

  defp delete_from_payload(payload) do
    case CodeMySpec.Repo.get(Project, payload["id"]) do
      nil -> :ok
      project -> CodeMySpec.Repo.delete(project)
    end
  rescue
    e ->
      Logger.warning("[ProjectsSocket] Failed to delete project: #{Exception.message(e)}")
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
