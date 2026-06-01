defmodule CodeMySpecLocalWeb.PermissionController do
  @moduledoc """
  Proxy for remote permission approval via the production server.

  One long-polling endpoint:

  - `create` — forwards the permission request to production, opens a
    WebSocket to listen for the user's decision, and blocks until either
    a decision arrives or the timeout fires. Returns the Claude Code
    PermissionRequest hook response directly in the HTTP body.

  Plus the response forwarder used by the production-side UI:

  - `respond` — forwards approve/deny to production.

  The previous design split the flow across `create` (returns request id)
  and `stream` (SSE-waits for decision), with the bash `approve` script
  bridging them and formatting the final hook response. Collapsing both
  halves into `create` lets the shell shim be a single curl invocation —
  no jq, no SSE parsing, no second hop.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Permissions.PermissionSocket

  @default_timeout_s 120
  @hook_event_name "PermissionRequest"

  def create(conn, params) do
    tool_name = Map.get(params, "tool_name")
    tool_input = Map.get(params, "tool_input", %{})
    timeout_ms = parse_timeout(params["timeout"]) * 1000

    if is_nil(tool_name) do
      conn |> put_status(400) |> json(%{error: "Missing required field: tool_name"})
    else
      case forward_create(tool_name, tool_input) do
        {:ok, %{"id" => request_id}} ->
          json(conn, hook_response(await_decision(request_id, timeout_ms)))

        {:ok, body} ->
          Logger.warning("[PermissionController] Unexpected create response: #{inspect(body)}")
          json(conn, hook_response("ask"))

        {:error, reason} ->
          Logger.warning(
            "[PermissionController] Failed to create on production: #{inspect(reason)}"
          )

          json(conn, hook_response("ask"))
      end
    end
  end

  def respond(conn, %{"id" => request_id} = params) do
    decision = Map.get(params, "decision")

    if decision in ~w(allow deny) do
      case forward_respond(request_id, decision) do
        :ok ->
          json(conn, %{status: "ok"})

        {:error, reason} ->
          conn
          |> put_status(502)
          |> json(%{error: "Failed to forward to production: #{inspect(reason)}"})
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

  # -- Decision wait -----------------------------------------------------------

  # Opens a WebSocket against production for `request_id` and blocks until
  # the user clicks (or timeout). Returns the hook `decision.behavior` value:
  # "allow", "deny", or "ask". Any error path resolves to "ask" so the agent
  # falls back to Claude Code's built-in prompt.
  defp await_decision(request_id, timeout_ms) do
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
            decision

          {:permission_error, reason} ->
            Process.demonitor(ref, [:flush])
            Logger.warning("[PermissionController] Channel error: #{inspect(reason)}")
            "ask"

          {:DOWN, ^ref, :process, ^pid, reason} ->
            Logger.warning("[PermissionController] Socket process exited: #{inspect(reason)}")
            "ask"
        after
          timeout_ms ->
            Process.demonitor(ref, [:flush])
            Process.exit(pid, :shutdown)
            "ask"
        end

      {:error, _reason} ->
        "ask"
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

  # -- Helpers -----------------------------------------------------------------

  defp hook_response(behavior) do
    %{
      "hookSpecificOutput" => %{
        "hookEventName" => @hook_event_name,
        "decision" => %{"behavior" => behavior}
      }
    }
  end

  defp parse_timeout(nil), do: @default_timeout_s

  defp parse_timeout(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> @default_timeout_s
    end
  end

  defp parse_timeout(val) when is_integer(val) and val > 0, do: val
  defp parse_timeout(_), do: @default_timeout_s
end
