defmodule CodeMySpecWeb.CliChannel do
  @moduledoc """
  Channel that the local `bin/cms` CLI joins to advertise its
  presence. The dashboard subscribes to the same topic via
  `CodeMySpecWeb.Presence` to drive the connection-status pill.

  Topic shape: `"cli:user:<user_id>"`.

  On the first successful join for a user, stamps
  `users.cli_first_connected_at` and dispatches a `:first_cli_connect`
  domain event so downstream observers (gating logic, GA forwarding,
  test subscribers) can react.
  """

  use CodeMySpecWeb, :channel
  require Logger

  alias CodeMySpec.Analytics
  alias CodeMySpec.Users
  alias CodeMySpecWeb.Presence

  @impl true
  def join("cli:user:" <> user_id_str, _payload, socket) do
    case Integer.parse(user_id_str) do
      {user_id, ""} ->
        socket_user_id = socket.assigns[:user_id]

        if user_id == socket_user_id do
          Logger.info("[CliChannel] join accepted user_id=#{user_id}")
          socket = assign(socket, :cli_user_id, user_id)
          send(self(), :after_join)
          maybe_record_first_connect(user_id)
          {:ok, socket}
        else
          Logger.warning(
            "[CliChannel] join rejected — user mismatch: topic_user=#{user_id} socket_user=#{inspect(socket_user_id)}"
          )

          {:error, %{reason: "user mismatch"}}
        end

      _ ->
        Logger.warning("[CliChannel] join rejected — invalid user_id: #{inspect(user_id_str)}")
        {:error, %{reason: "invalid user_id"}}
    end
  end

  @impl true
  def join(topic, _payload, _socket) do
    Logger.warning("[CliChannel] join rejected — invalid topic: #{inspect(topic)}")
    {:error, %{reason: "invalid topic"}}
  end

  # Local app pushes activation milestones over the channel — we relay
  # each into Analytics with origin :server so the GA Measurement
  # Protocol path picks them up. Whitelisted to keep arbitrary atoms
  # out of the system.
  @activation_events ~w(
    local_signed_in
    local_project_linked
    local_init_complete
    local_project_setup_complete
    first_local_story_created
  )

  @impl true
  def handle_in("activation_event", %{"name" => name, "payload" => payload}, socket)
      when name in @activation_events do
    user_id = socket.assigns[:cli_user_id]

    payload = normalize_activation_payload(payload, user_id)

    Logger.info("[CliChannel] activation_event #{name} user_id=#{user_id}")

    Analytics.dispatch(String.to_atom(name), payload, :server)

    {:reply, :ok, socket}
  end

  def handle_in("activation_event", payload, socket) do
    Logger.warning("[CliChannel] activation_event rejected — bad shape: #{inspect(payload)}")
    {:reply, {:error, %{reason: "invalid activation_event"}}, socket}
  end

  defp normalize_activation_payload(payload, user_id) when is_map(payload) do
    payload
    |> Enum.into(%{}, fn
      {"user_id", v} -> {:user_id, v}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.put_new(:user_id, user_id)
  end

  defp normalize_activation_payload(_payload, user_id), do: %{user_id: user_id}

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.cli_user_id
    presence_key = "cli:#{System.unique_integer([:positive])}"

    {:ok, _ref} =
      Presence.track(socket, presence_key, %{
        joined_at: System.system_time(:second)
      })

    Logger.info(
      "[CliChannel] presence tracked user_id=#{user_id} key=#{presence_key} count=#{
        map_size(Presence.list("cli:user:#{user_id}"))
      }"
    )

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      status_topic(user_id),
      :cli_presence_changed
    )

    {:noreply, assign(socket, :presence_key, presence_key)}
  end

  @impl true
  def terminate(reason, socket) do
    if user_id = socket.assigns[:cli_user_id] do
      Logger.info("[CliChannel] terminate user_id=#{user_id} reason=#{inspect(reason)}")

      if presence_key = socket.assigns[:presence_key] do
        # Untrack synchronously so subscribers refreshing on the
        # broadcast below see the leave reflected in `Presence.list/1`.
        # Phoenix.Presence's monitor-driven untrack runs *after* the
        # channel pid exits, which is a race for tight-loop tests.
        Presence.untrack(self(), "cli:user:#{user_id}", presence_key)
      end

      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        status_topic(user_id),
        :cli_presence_changed
      )
    end

    :ok
  end

  @doc """
  PubSub topic LiveViews subscribe to for CLI presence change
  notifications. Distinct from the channel topic
  (`"cli:user:<id>"`) so the channel does not receive its own
  broadcasts.
  """
  def status_topic(user_id), do: "cli_status:user:#{user_id}"

  defp maybe_record_first_connect(user_id) do
    user = Users.get_user!(user_id)

    if Users.cli_ever_connected?(user) do
      :ok
    else
      case Users.mark_cli_first_connect(user) do
        {:ok, _user} ->
          Analytics.dispatch(:first_cli_connect, %{user_id: user_id})

        {:error, _changeset} ->
          :ok
      end
    end
  end
end
