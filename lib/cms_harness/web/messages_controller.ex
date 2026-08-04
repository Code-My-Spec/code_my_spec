defmodule CmsHarness.Web.MessagesController do
  @moduledoc """
  The Anthropic-shaped endpoint a sprite's agent talks to.

  A sprite sets `ANTHROPIC_BASE_URL` here, so every model turn arrives as a
  plain `/v1/messages` request. The turn is forwarded unchanged and the
  upstream response returned unchanged — an agent must not be able to tell it
  is proxied, or the watching has altered the thing it set out to measure.

  The record goes to the server, not to disk. Same split as observations: the
  harness holds a working copy, the server holds what happened, and the
  operator reads it there.
  """
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Projects

  @upstream "https://api.anthropic.com"

  # `conn.body_params`, not the action's `params`: Phoenix merges the query
  # string into params, and Claude Code calls this as `/v1/messages?beta=true`.
  # Forwarding the merged map put `beta` in the JSON body, where Anthropic
  # rejects it — "Extra inputs are not permitted" — and every turn 400'd. A
  # proxy has to send the body it was given and leave the query where it was.
  def create(conn, _params) do
    params = conn.body_params

    case forward(params, forwarded_headers(conn), conn.query_string) do
      {:ok, %{status: 200, body: body}} ->
        record(conn, params, body)
        json(conn, body)

      {:ok, %{status: status, body: body}} ->
        conn |> put_status(status) |> json(body)

      {:error, reason} ->
        Logger.error("[CmsHarness] upstream call failed: #{inspect(reason)}")

        conn
        |> put_status(502)
        |> json(%{"type" => "error", "error" => %{"message" => "upstream unreachable"}})
    end
  end

  defp forward(request, headers, query_string) do
    [
      url: base_url() <> "/v1/messages" <> query_suffix(query_string),
      json: request,
      headers: headers,
      decode_json: [keys: :strings],
      # The agent has its own retry and backoff; a second layer here turns one
      # slow turn into several and hides the latency from both ends.
      retry: false,
      receive_timeout: 600_000
    ]
    |> Req.new()
    |> Req.post()
  end

  # The record is sent after the response is composed and never awaited — see
  # ChannelClient.record_turn/2. A turn that reached the agent has succeeded
  # whatever the server later does with the record of it.
  defp record(conn, request, response) do
    case project_id() do
      nil ->
        Logger.warning("[CmsHarness] no project configured — turn not recorded")

      project_id ->
        ChannelClient.record_turn(project_id, %{
          "session_id" => header(conn, "x-cms-session-id", "sprite"),
          "agent_role" => header(conn, "x-agent-role", "main"),
          "request" => request,
          "response" => response
        })
    end

    :ok
  end

  # A sprite serves exactly one project and is told which at boot, so the
  # record needs no header to say where it belongs.
  defp project_id do
    case Projects.list() do
      [id] -> id
      _ -> nil
    end
  end

  defp header(conn, name, default) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when value != "" -> value
      _ -> default
    end
  end

  # The proxy holds no credential of its own — a sprite's agent authenticates
  # as itself. Anything else Anthropic needs rides along untouched.
  @forwarded ~w(authorization x-api-key anthropic-version anthropic-beta)

  defp forwarded_headers(conn) do
    Enum.flat_map(@forwarded, fn name ->
      case Plug.Conn.get_req_header(conn, name) do
        [value | _] -> [{name, value}]
        [] -> []
      end
    end)
  end

  defp query_suffix(""), do: ""
  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query

  defp base_url, do: System.get_env("ANTHROPIC_UPSTREAM_URL") || @upstream
end
