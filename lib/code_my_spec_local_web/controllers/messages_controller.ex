defmodule CodeMySpecLocalWeb.MessagesController do
  @moduledoc """
  The Anthropic-shaped endpoint a sprite's agent talks to.

  A sprite sets `ANTHROPIC_BASE_URL` here, so every model turn arrives as a
  plain `/v1/messages` request. This forwards it unchanged and hands back the
  upstream response unchanged — the agent cannot tell it is being watched,
  which is the point. Recording happens on the way past.

  The response is returned before the recording is considered. A turn that
  succeeded upstream has succeeded, whatever the conversation store thinks
  (story 984, criterion 8175).
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.AgentHarness.ConversationRecorder

  def create(conn, params) do
    scope = conn.assigns.current_scope

    case ConversationRecorder.forward(params, headers: forwarded_headers(conn)) do
      {:ok, response} ->
        record(scope, conn, params, response)
        json(conn, response)

      {:error, {:upstream_status, status, body}} ->
        conn |> put_status(status) |> json(body)

      {:error, reason} ->
        Logger.error("[Messages] upstream call failed: #{inspect(reason)}")

        conn
        |> put_status(502)
        |> json(%{"type" => "error", "error" => %{"message" => "upstream unreachable"}})
    end
  end

  # The recording is deliberately not part of the response path: its return is
  # ignored and its failure is the recorder's to log. See the moduledoc.
  defp record(scope, conn, params, response) do
    _ =
      ConversationRecorder.record_turn(
        scope.active_account_id,
        scope.active_project_id,
        session_id(conn),
        params,
        response
      )

    :ok
  end

  # One conversation per agent session. Falls back to the project so a turn
  # arriving without a session header is still visible rather than dropped.
  defp session_id(conn) do
    case get_req_header(conn, "x-cms-session-id") do
      [id | _] when id != "" -> id
      _ -> "sprite"
    end
  end

  # Authorization is the caller's own key — this proxy holds no credential of
  # its own and must not invent one. Anything else Anthropic needs (beta flags,
  # version) rides along untouched.
  @forwarded ~w(authorization x-api-key anthropic-version anthropic-beta)

  defp forwarded_headers(conn) do
    Enum.flat_map(@forwarded, fn name ->
      case get_req_header(conn, name) do
        [value | _] -> [{name, value}]
        [] -> []
      end
    end)
  end
end
