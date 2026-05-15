defmodule CodeMySpec.Permissions.TapOutWaiter do
  @moduledoc """
  Waits for a remote tap-out decision and applies it to the local session.

  Started by `Permissions.TapOut.request/2` after forwarding the request to
  the production server. Opens a `PermissionSocket` to production's
  `permission:<id>` channel, blocks on `{:permission_decision, decision}`,
  then calls `TapOut.respond/4` to apply the decision locally
  (`:approve` clears `session.continuous`; `:reject` leaves it on).
  """

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Permissions.PermissionSocket
  alias CodeMySpec.Permissions.TapOut
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope

  @timeout_ms 600_000

  @spec start(Scope.t(), String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Scope{} = scope, session_id, request_id)
      when is_binary(session_id) and is_binary(request_id) do
    Task.Supervisor.start_child(
      CodeMySpec.Permissions.TaskSupervisor,
      fn -> run(scope, session_id, request_id) end
    )
  end

  defp run(scope, session_id, request_id) do
    case build_ws_url() do
      {:ok, ws_url} ->
        {:ok, pid} =
          PermissionSocket.start_link(
            caller: self(),
            uri: ws_url,
            request_id: request_id
          )

        ref = Process.monitor(pid)
        wait_for_decision(scope, session_id, request_id, ref, pid)

      {:error, reason} ->
        Logger.warning("[TapOutWaiter] no oauth token, skipping wait for #{request_id}: #{inspect(reason)}")
    end
  end

  defp wait_for_decision(scope, session_id, request_id, ref, pid) do
    receive do
      {:permission_decision, "allow"} ->
        Process.demonitor(ref, [:flush])
        apply_decision(scope, session_id, request_id, :approve)

      {:permission_decision, "deny"} ->
        Process.demonitor(ref, [:flush])
        apply_decision(scope, session_id, request_id, :reject)

      {:permission_error, reason} ->
        Process.demonitor(ref, [:flush])
        Logger.warning("[TapOutWaiter] permission error for #{request_id}: #{inspect(reason)}")

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.warning("[TapOutWaiter] socket exited for #{request_id}: #{inspect(reason)}")
    after
      @timeout_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :shutdown)
        Logger.warning("[TapOutWaiter] timeout waiting for #{request_id}")
    end
  end

  defp apply_decision(scope, session_id, request_id, decision) do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        Logger.warning("[TapOutWaiter] session #{session_id} not found when applying #{decision}")

      session ->
        case TapOut.respond(scope, session, request_id, decision) do
          {:ok, _} ->
            Logger.info("[TapOutWaiter] applied #{decision} for #{request_id}")

          {:error, reason} ->
            Logger.warning("[TapOutWaiter] respond/4 failed for #{request_id}: #{inspect(reason)}")
        end
    end
  end

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
