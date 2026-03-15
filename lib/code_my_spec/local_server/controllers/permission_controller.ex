defmodule CodeMySpec.LocalServer.Controllers.PermissionController do
  @moduledoc """
  Handles remote permission approval for Claude Code hooks.

  The local server acts as a proxy:
  1. `create/1` — forwards the permission request to the production server
     (which stores it and sends Web Push)
  2. `stream/1` — SSE endpoint the hook script holds open via `curl -N`,
     connects to production via Phoenix Channel and waits for the decision
  3. `respond/1` — local convenience endpoint that forwards to production

  The permission request record lives on the production server so the user's
  phone can approve/deny via the production LiveView without needing to reach
  the local machine.
  """

  import Plug.Conn
  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.LocalServer.PermissionSocket

  @default_timeout_s 120

  def create(conn) do
    body = conn.body_params

    tool_name = Map.get(body, "tool_name")
    tool_input = Map.get(body, "tool_input", %{})

    if is_nil(tool_name) do
      json_response(conn, 400, %{error: "Missing required field: tool_name"})
    else
      case forward_create(tool_name, tool_input) do
        {:ok, %{"id" => id}} ->
          json_response(conn, 201, %{id: id})

        {:error, reason} ->
          Logger.warning("[PermissionController] Failed to create on production: #{inspect(reason)}")
          json_response(conn, 502, %{error: "Failed to reach production server"})
      end
    end
  end

  def stream(conn) do
    request_id = conn.params["id"]
    timeout_s = parse_timeout(conn.params["timeout"])
    timeout_ms = timeout_s * 1000

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> await_decision_via_channel(request_id, timeout_ms)
  end

  def respond(conn) do
    request_id = conn.params["id"]
    decision = get_in(conn.body_params, ["decision"])

    if decision in ~w(allow deny) do
      case forward_respond(request_id, decision) do
        :ok ->
          json_response(conn, 200, %{status: "ok"})

        {:error, reason} ->
          json_response(conn, 502, %{error: "Failed to forward to production: #{inspect(reason)}"})
      end
    else
      json_response(conn, 400, %{error: "Invalid decision. Must be 'allow' or 'deny'"})
    end
  end

  # --- Production API calls ---

  defp forward_create(tool_name, tool_input) do
    with {:ok, token} <- OAuthClient.get_token() do
      server_url = OAuthClient.get_server_url()
      url = "#{server_url}/api/permissions/request"
      headers = [{"authorization", "Bearer #{token}"}]

      case Req.post(url, headers: headers, json: %{tool_name: tool_name, tool_input: tool_input}) do
        {:ok, %{status: status, body: body}} when status in [200, 201] ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp forward_respond(request_id, decision) do
    with {:ok, token} <- OAuthClient.get_token() do
      server_url = OAuthClient.get_server_url()
      url = "#{server_url}/api/permissions/#{request_id}/respond"
      headers = [{"authorization", "Bearer #{token}"}]

      case Req.post(url, headers: headers, json: %{decision: decision}) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- Channel-based decision waiting ---

  defp await_decision_via_channel(conn, request_id, timeout_ms) do
    case build_ws_url() do
      {:ok, ws_url} ->
        {:ok, pid} =
          PermissionSocket.start_link(
            caller: self(),
            uri: ws_url,
            request_id: request_id
          )

        ref = Process.monitor(pid)

        receive do
          {:permission_decision, decision} ->
            Process.demonitor(ref, [:flush])
            send_sse_event(conn, %{decision: decision})

          {:permission_error, reason} ->
            Process.demonitor(ref, [:flush])
            Logger.warning("[PermissionController] Channel error: #{inspect(reason)}")
            send_sse_event(conn, %{decision: "ask", reason: "channel_error"})

          {:DOWN, ^ref, :process, ^pid, reason} ->
            Logger.warning("[PermissionController] Socket process exited: #{inspect(reason)}")
            send_sse_event(conn, %{decision: "ask", reason: "socket_exit"})
        after
          timeout_ms ->
            Process.demonitor(ref, [:flush])
            Process.exit(pid, :shutdown)
            Logger.debug("[PermissionController] Timed out waiting for decision on #{request_id}")
            send_sse_event(conn, %{decision: "ask", reason: "timeout"})
        end

      {:error, reason} ->
        Logger.warning("[PermissionController] Failed to build WS URL: #{inspect(reason)}")
        send_sse_event(conn, %{decision: "ask", reason: "no_token"})
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

  defp send_sse_event(conn, data) do
    chunk(conn, "data: #{Jason.encode!(data)}\n\n")
    conn
  end

  defp parse_timeout(nil), do: @default_timeout_s

  defp parse_timeout(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> @default_timeout_s
    end
  end

  defp parse_timeout(_), do: @default_timeout_s

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
