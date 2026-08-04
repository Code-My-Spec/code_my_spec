defmodule CmsHarness.Web.McpController do
  @moduledoc """
  The MCP surface, forwarded to the server.

  The light harness has no tools of its own — they moved to the server, where
  the model is. What it has is the one thing the server does not: it is a
  process on the developer's machine, at a `localhost` URL, that Claude Code
  will talk to over plain HTTP without a certificate.

  So this forwards. Whole JSON-RPC messages in, whole messages back, at the
  transport layer, with no knowledge of the 83 tools passing through it. That is
  deliberate: a proxy that understood the tools would be a second place every
  new tool has to be added, and would drift.

  ## What it adds

  Two headers the server needs and Claude Code cannot supply:

    * `Authorization: Bearer <token>` — `CmsHarness.Config.credential/0`, the
      same credential the project channel authenticates with. One credential,
      two transports; the server derives the user from it either way.
    * `X-Project-ID` — resolved from `?dir=`, exactly as the plugin already
      sends it to the heavy harness. `ProjectIdentity.resolve/1` reads it out of
      `.code_my_spec/config.yml` with no database, which is the whole trick: a
      server with no disk cannot answer which project a path is, and does not
      have to.

  Because the URL shape is the one the plugin already uses for `local`, this is
  a drop-in: the same `http://localhost:PORT/mcp?dir=${CLAUDE_PROJECT_DIR}`,
  answered by a different process. Tool names stay
  `mcp__plugin_codemyspec_local__*`, so every prompt reference, every agent's
  `mcpServers: local` and the PreToolUse prefix keep working.

  ## Deploy keys do not work here yet

  `CmsHarness.Config.credential/0` also accepts `CMS_DEPLOY_KEY`, and the
  server's `UserSocket` takes one — but `/mcp/harness` is behind
  `require_oauth_token`, which only accepts an OAuth access token. A sprite's
  channel therefore connects while its MCP requests 401. The 401 is passed
  through with that named in the log rather than being translated into
  something friendlier, because the fix is on the server and a softened error
  would hide which end owes the work.

  ## No refresh

  `CodeMySpec.Auth.OAuthClient` refreshes tokens, and this does not use it: that
  module reads `ClientUser` rows through the Repo, and a harness with a Repo is
  not the light harness. So the token here is whatever `CMS_TOKEN` holds, and it
  expires. Giving the harness its own file-backed credential store is the next
  piece of work, not something to fake with a database.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.ProjectIdentity

  # Everything the MCP transport puts on a request that means something to the
  # far end. `authorization` is deliberately absent — Claude Code sends none,
  # and this adds its own.
  @forwarded ~w(accept content-type mcp-session-id mcp-protocol-version last-event-id)

  # What the far end sends back that the client's transport reads. Content type
  # is set separately because Phoenix owns it on the conn.
  @returned ~w(mcp-session-id mcp-protocol-version)

  # A POST is one request and one answer; Anubis always replies JSON to it.
  @post_timeout to_timeout(minute: 5)

  def proxy(conn, _params) do
    with {:ok, project} <- project(conn),
         {:ok, token} <- Config.credential() do
      dispatch(conn, project, token)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # GET is the server→client channel: long-lived, and the only way a
  # server-initiated request (`ask_user`, elicitation) reaches the agent. It is
  # streamed rather than buffered, because buffering it would mean the agent
  # never sees anything until the session ends.
  defp dispatch(%{method: "GET"} = conn, project, token) do
    stream(conn, request(conn, project, token, :get, nil, :infinity))
  end

  defp dispatch(%{method: method} = conn, project, token) when method in ~w(POST DELETE) do
    verb = if method == "POST", do: :post, else: :delete
    body = if verb == :post, do: body(conn), else: nil

    case Req.request(request(conn, project, token, verb, body, @post_timeout)) do
      {:ok, response} ->
        conn
        |> copy_headers(response)
        |> put_resp_content_type(content_type(response))
        |> send_resp(response.status, response.body || "")

      {:error, reason} ->
        unreachable(conn, reason)
    end
  end

  defp dispatch(conn, _project, _token) do
    send_resp(conn, 405, "")
  end

  defp request(conn, project, token, method, body, receive_timeout) do
    Req.new(
      method: method,
      url: Config.server_url() |> String.trim_trailing("/") |> Kernel.<>("/mcp/harness"),
      headers: headers(conn, project, token),
      body: body,
      # The response is relayed verbatim; decoding it here would only mean
      # re-encoding it, and a re-encode is a chance to change something.
      decode_body: false,
      # Claude Code has its own retry. A second layer turns one slow call into
      # several and hides the latency from both ends.
      retry: false,
      receive_timeout: receive_timeout
    )
  end

  defp headers(conn, project, token) do
    forwarded =
      Enum.flat_map(@forwarded, fn name ->
        case get_req_header(conn, name) do
          [value | _] -> [{name, value}]
          [] -> []
        end
      end)

    [{"authorization", "Bearer " <> token}, {"x-project-id", project.id} | forwarded]
  end

  # `conn.body_params`, re-encoded. Plug.Parsers has already consumed the body
  # by the time an action runs, so there is no raw copy left to pass on. Key
  # order is the only thing lost and JSON-RPC does not depend on it.
  #
  # A batch arrives as a top-level array, which Plug.Parsers stores under
  # `_json`; sending the wrapper would be a message the server cannot parse.
  defp body(conn) do
    case conn.body_params do
      %{"_json" => batch} -> Jason.encode!(batch)
      params -> Jason.encode!(params)
    end
  end

  # `into: :self` rather than a callback, because the status has to be known
  # before anything is sent: an upstream 401 must reach the client as a 401, and
  # a stream opened optimistically would have already committed to 200.
  defp stream(conn, req) do
    case Req.request(req, into: :self) do
      {:ok, %{status: 200} = response} ->
        conn
        |> copy_headers(response)
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)
        |> pump(response.body)

      {:ok, response} ->
        Logger.warning("[CmsHarness] MCP stream refused upstream: #{response.status}")

        conn
        |> copy_headers(response)
        |> put_resp_content_type(content_type(response))
        |> send_resp(response.status, Enum.join(Enum.to_list(response.body)))

      {:error, reason} ->
        unreachable(conn, reason)
    end
  end

  defp pump(conn, chunks) do
    Enum.reduce_while(chunks, conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        # The agent went away. Nothing to log: closing the tab is the normal end
        # of an MCP session, not a fault.
        {:error, _reason} -> {:halt, conn}
        {:ok, conn} -> {:cont, conn}
      end
    end)
  end

  defp copy_headers(conn, response) do
    Enum.reduce(@returned, conn, fn name, conn ->
      case Req.Response.get_header(response, name) do
        [value | _] -> put_resp_header(conn, name, value)
        [] -> conn
      end
    end)
  end

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value |> String.split(";") |> hd() |> String.trim()
      [] -> "application/json"
    end
  end

  # The plugin sends `?dir=${CLAUDE_PROJECT_DIR}` — the same URL shape the heavy
  # harness is configured with, so switching between them is a port and nothing
  # else. `X-Working-Dir` is accepted too because the hook surface uses it and
  # somebody will reasonably expect it to work here. `CMS_PROJECT_DIR` is the
  # sprite, which serves one project and is told which at boot.
  defp project(conn) do
    dir =
      conn.query_params["dir"] ||
        List.first(get_req_header(conn, "x-working-dir")) ||
        System.get_env("CMS_PROJECT_DIR") ||
        Application.get_env(:code_my_spec, :harness_project_dir)

    case dir do
      dir when is_binary(dir) and dir != "" -> ProjectIdentity.resolve(dir)
      _ -> {:error, :no_working_dir}
    end
  end

  # A JSON-RPC error rather than an HTTP one: the client is an MCP transport,
  # and a bare 400 shows up in Claude Code as "the server is broken" with
  # nothing about which of these five things went wrong.
  defp refuse(conn, reason) do
    Logger.error("[CmsHarness] MCP refused: #{inspect(reason)}")

    conn
    |> put_status(200)
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => conn.body_params["id"],
      "error" => %{"code" => -32_000, "message" => message(reason)}
    })
  end

  defp message(:no_credential),
    do:
      "The CodeMySpec harness has no credential for the server, so it cannot " <>
        "forward this. Set CMS_TOKEN and restart it. (A sprite's CMS_DEPLOY_KEY " <>
        "authenticates the project channel but not MCP — the server's /mcp/harness " <>
        "accepts only an OAuth access token.)"

  defp message(:no_working_dir),
    do:
      "No working directory on this request, so the harness cannot say which " <>
        "project it is about. The plugin sends it as ?dir=${CLAUDE_PROJECT_DIR}."

  defp message(:no_project_id),
    do:
      "This directory does not say which project it is. Put a `project_id` in " <>
        ".code_my_spec/config.yml, or set CMS_PROJECT_ID."

  defp message(:unreadable_config),
    do: "The harness could not read .code_my_spec/config.yml in this directory."

  defp message({:invalid_config, reason}),
    do: "The harness could not parse .code_my_spec/config.yml: #{inspect(reason)}"

  defp message(reason), do: "The CodeMySpec harness could not forward this: #{inspect(reason)}"

  defp unreachable(conn, reason) do
    Logger.error("[CmsHarness] MCP upstream unreachable: #{inspect(reason)}")

    conn
    |> put_status(200)
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => conn.body_params["id"],
      "error" => %{
        "code" => -32_000,
        "message" =>
          "The CodeMySpec harness could not reach #{Config.server_url()}: #{inspect(reason)}"
      }
    })
  end
end
