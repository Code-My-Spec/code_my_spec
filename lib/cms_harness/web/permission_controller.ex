defmodule CmsHarness.Web.PermissionController do
  @moduledoc """
  Remote permission approval: ask the person, on their phone, before the agent
  runs the tool.

  Claude Code's `PermissionRequest` hook posts here and blocks on the answer.
  This forwards the request to the server, waits on a websocket for someone to
  tap approve or deny, and hands back the hook response. Same shape as
  `CodeMySpecLocalWeb.PermissionController`, which this is deliberately a near
  copy of — the flow was already proven there, and the only things that differ
  are where the credential comes from and where the server is.

  ## Everything that goes wrong answers "ask"

  A proxy standing between an agent and a permission prompt must never turn a
  failure into an approval. No credential, no server, no reply inside the
  timeout, a socket that dies — all of them resolve to `"ask"`, which puts
  Claude Code's own prompt in front of whoever is at the terminal. The
  degradation is "you are asked locally", never "it went ahead".

  ## Why it opens its own socket

  The harness already holds a channel per project, and this does not use it.
  The decision arrives on `permission:<request_id>`, a topic that exists for one
  request and is subscribed per request; multiplexing it onto the project
  channel would mean routing by request id through a process whose job is file
  state, and blocking that process for two minutes while a person decides.
  A short-lived socket per request costs a connection and keeps the project
  channel answering hooks.

  It authenticates with the *exchanged* token rather than the deploy key:
  `PermissionChannel.join/3` refuses a socket with no `user_id`, and the point
  of the exchange is that it produces a token with a real resource owner —
  the project's account owner, which is the person who should be deciding.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.Token
  alias CmsHarness.Web.UpstreamError
  alias CodeMySpec.Permissions.PermissionSocket

  @default_timeout_s 120
  @hook_event_name "PermissionRequest"
  @request_path "/api/permissions/request"

  def create(conn, params) do
    tool_name = Map.get(params, "tool_name")

    if is_nil(tool_name) do
      conn |> put_status(400) |> json(%{error: "Missing required field: tool_name"})
    else
      tool_input = Map.get(params, "tool_input", %{})
      timeout_ms = parse_timeout(params["timeout"]) * 1000

      json(conn, hook_response(decide(tool_name, tool_input, timeout_ms)))
    end
  end

  defp decide(tool_name, tool_input, timeout_ms) do
    case request_decision(tool_name, tool_input) do
      {:ok, request_id} ->
        await_decision(request_id, timeout_ms)

      {:error, reason} ->
        Logger.warning("[CmsHarness] permission request not raised: #{inspect(reason)}")
        "ask"
    end
  end

  defp request_decision(tool_name, tool_input) do
    with {:ok, token} <- Token.access_token() do
      url = Config.server_url() |> String.trim_trailing("/") |> Kernel.<>(@request_path)

      request =
        Req.new(
          method: :post,
          url: url,
          headers: [{"authorization", "Bearer " <> token}],
          json: %{tool_name: tool_name, tool_input: tool_input},
          retry: false,
          receive_timeout: 30_000
        )

      case Req.request(request) do
        {:ok, %{status: status, body: %{"id" => id}}} when status in [200, 201] -> {:ok, id}
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, readable(body, status)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The caller of this logs the reason, so an unread body is a 30KB HTML page in
  # one log line. Same wedged dev server, same document, different reader — and
  # here it lands in `harness.log`, where the metadata truncation does not apply
  # because this is the message rather than metadata (6ecb257a).
  #
  # Only a binary can be a page. Req decodes JSON to a map, and a map is already
  # as short as the server made it.
  defp readable(body, status) when is_binary(body) do
    UpstreamError.summary(body, status, nil) || String.slice(body, 0, 300)
  end

  defp readable(body, _status), do: body

  # Blocks until the person decides or the timeout fires. Monitored, so a socket
  # that dies is answered rather than waited out — the agent is holding a hook
  # open on this and two minutes of silence is the worst answer available.
  defp await_decision(request_id, timeout_ms) do
    case socket_url() do
      {:ok, uri} ->
        {:ok, pid} = PermissionSocket.start_link(caller: self(), uri: uri, request_id: request_id)
        ref = Process.monitor(pid)

        receive do
          {:permission_decision, decision} ->
            Process.demonitor(ref, [:flush])
            decision

          {:permission_error, reason} ->
            Process.demonitor(ref, [:flush])
            Logger.warning("[CmsHarness] permission channel error: #{inspect(reason)}")
            "ask"

          {:DOWN, ^ref, :process, ^pid, reason} ->
            Logger.warning("[CmsHarness] permission socket exited: #{inspect(reason)}")
            "ask"
        after
          timeout_ms ->
            Process.demonitor(ref, [:flush])
            Process.exit(pid, :shutdown)
            Logger.info("[CmsHarness] nobody answered the permission request; asking locally")
            "ask"
        end

      {:error, reason} ->
        Logger.warning("[CmsHarness] no socket for the decision: #{inspect(reason)}")
        "ask"
    end
  end

  # The exchanged token, not `Config.socket_url/0` — that one carries whatever
  # the project channel authenticates with, and a deploy key has no `user_id`
  # for `PermissionChannel.join/3` to accept.
  defp socket_url do
    with {:ok, token} <- Token.access_token() do
      url =
        Config.server_url()
        |> String.replace(~r{^https://}, "wss://")
        |> String.replace(~r{^http://}, "ws://")
        |> String.trim_trailing("/")
        |> Kernel.<>("/socket/websocket?token=#{token}&vsn=2.0.0")

      {:ok, url}
    end
  end

  defp hook_response(behavior) do
    %{
      "hookSpecificOutput" => %{
        "hookEventName" => @hook_event_name,
        "decision" => %{"behavior" => behavior}
      }
    }
  end

  defp parse_timeout(nil), do: @default_timeout_s

  defp parse_timeout(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _} when seconds > 0 -> seconds
      _ -> @default_timeout_s
    end
  end

  defp parse_timeout(value) when is_integer(value) and value > 0, do: value
  defp parse_timeout(_), do: @default_timeout_s
end
