defmodule CodeMySpecLocalWeb.PermissionController do
  @moduledoc """
  Proxy for remote permission approval via the production server.

  1. `create` — forwards the permission request to production (stores + Web Push)
  2. `stream` — SSE endpoint held open by hook script, waits for decision via channel
  3. `respond` — forwards approval/denial to production
  """
  use CodeMySpecLocalWeb, :controller

  import Plug.Conn

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Permissions.PermissionSocket

  @default_timeout_s 120

  def create(conn, params) do
    tool_name = Map.get(params, "tool_name")
    tool_input = Map.get(params, "tool_input", %{})

    if is_nil(tool_name) do
      conn |> put_status(400) |> json(%{error: "Missing required field: tool_name"})
    else
      case forward_create(tool_name, tool_input) do
        {:ok, %{"id" => id}} ->
          conn |> put_status(201) |> json(%{id: id})

        {:error, reason} ->
          Logger.warning("[PermissionController] Failed to create on production: #{inspect(reason)}")
          conn |> put_status(502) |> json(%{error: "Failed to reach production server"})
      end
    end
  end

  def stream(conn, %{"id" => request_id} = params) do
    timeout_s = parse_timeout(params["timeout"])
    timeout_ms = timeout_s * 1000

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> await_decision_via_channel(request_id, timeout_ms)
  end

  def respond(conn, %{"id" => request_id} = params) do
    decision = Map.get(params, "decision")

    if decision in ~w(allow deny) do
      case forward_respond(request_id, decision) do
        :ok ->
          json(conn, %{status: "ok"})

        {:error, reason} ->
          conn |> put_status(502) |> json(%{error: "Failed to forward to production: #{inspect(reason)}"})
      end
    else
      conn |> put_status(400) |> json(%{error: "Invalid decision. Must be 'allow' or 'deny'"})
    end
  end

  # -- Production API calls ----------------------------------------------------

  defp forward_create(tool_name, tool_input) do
    with {:ok, token} <- OAuthClient.get_token() do
      server_url = OAuthClient.get_server_url()
      url = "#{server_url}/api/permissions/request"
      headers = [{"authorization", "Bearer #{token}"}]

      case Req.post(url, headers: headers, json: %{tool_name: tool_name, tool_input: tool_input}) do
        {:ok, %{status: status, body: body}} when status in [200, 201] -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
        {:error, reason} -> {:error, reason}
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

  # -- Channel-based decision waiting -----------------------------------------

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
            send_sse_event(conn, %{decision: "ask", reason: "timeout"})
        end

      {:error, _reason} ->
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
end
