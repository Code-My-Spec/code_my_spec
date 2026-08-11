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
    * `X-Project-ID` — resolved from the harness id in `?harness=`.
      `ProjectIdentity.resolve/1` reads it out of `.code_my_spec/config.yml`
      with no database, which is the whole trick: a server with no disk cannot
      answer which project a path is, and does not have to.

  The session is addressed by harness id, not by directory. Two checkouts of
  one project are two working copies with two ids, and were they addressed by
  path they would share an MCP session while their hooks stayed apart — which
  is worse than either alternative, because the mismatch is invisible.

  Tool names stay `mcp__plugin_codemyspec_local__*`, so every prompt reference,
  every agent's `mcpServers: local` and the PreToolUse prefix keep working.

  ## The credential comes from `CmsHarness.Token`, not `Config.credential/0`

  `/mcp/harness` sits behind `require_oauth_token`, which takes a user's OAuth
  access token and nothing else — not a deploy key, which is what a sprite
  holds. `Token.access_token/0` is the piece that reconciles those: it hands
  back a user token when the machine has one, and otherwise trades the deploy
  key for a short-lived one at `POST /api/sprite/token`. It also handles expiry,
  which is why there is no refresh problem here to write about.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.ProjectIdentity
  alias CmsHarness.Token
  alias CmsHarness.Web.UpstreamError
  alias CmsHarness.WorkingCopies

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
         {:ok, token} <- Token.access_token() do
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
        relay_or_summarize(conn, response)

      {:error, reason} ->
        unreachable(conn, reason)
    end
  end

  defp dispatch(conn, _project, _token) do
    send_resp(conn, 405, "")
  end

  # An error page is never a tool result, so it is summarized rather than
  # relayed.
  #
  # When the upstream dev server is wedged — a `config/*.exs` change it cannot
  # hot-reload — every request gets Phoenix's styled `CompileError` page. That
  # was passed through verbatim: 30KB of markup and a base64 SVG logo arriving
  # in an agent's context as the result of `create_issue`, which is to say the
  # tool for reporting friction failed by burning the context needed to report
  # it (issues 5fb011f4, 6ecb257a).
  #
  # Only error pages are caught. A JSON body is a result and an SSE stream is the
  # server→client channel, both legitimate; guessing "not JSON means broken"
  # would break streaming.
  defp relay_or_summarize(conn, response) do
    case html_summary(response) do
      nil ->
        conn
        |> copy_headers(response)
        |> put_resp_content_type(content_type(response))
        |> send_resp(response.status, response.body || "")

      summary ->
        Logger.error("[CmsHarness] MCP upstream returned an error page: #{summary}")

        conn
        |> put_status(200)
        |> json(%{
          "jsonrpc" => "2.0",
          "id" => conn.body_params["id"],
          "error" => %{"code" => -32_001, "message" => summary}
        })
    end
  end

  defp html_summary(response),
    do: UpstreamError.summary(to_string(response.body || ""), response.status, content_type(response))

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

    # The harness id travels too, not just the project. Two checkouts of one
    # project are one `x-project-id`, so without this the far end cannot tell
    # them apart and answers about all of them: `await_analysis` reported 1132
    # credo problems to a working copy that had 563, the remainder belonging to
    # a checkout it cannot see. The id is already resolved here — `project/1`
    # looks the project up *through* it — it was simply not passed on.
    [
      {"authorization", "Bearer " <> token},
      {"x-project-id", project.id}
      | harness_header(conn) ++ forwarded
    ]
  end

  defp harness_header(conn) do
    case conn.query_params["harness"] || List.first(get_req_header(conn, "x-harness-id")) do
      id when is_binary(id) and id != "" -> [{"x-harness-id", id}]
      _ -> []
    end
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

  # `?harness=<id>`, written by onboarding. The header is accepted too, for a
  # host that cannot template a URL. Nothing else — a directory is not an
  # answer to "which working copy is this", which is why it is not consulted.
  defp project(conn) do
    case conn.query_params["harness"] || List.first(get_req_header(conn, "x-harness-id")) do
      id when is_binary(id) and id != "" -> by_harness(id)
      _ -> {:error, :no_harness}
    end
  end

  # `?harness=<id>` is the addressed form, matching the hook surface. The id
  # says which working copy without the directory being consulted, which is
  # what lets two checkouts of one project hold separate MCP sessions.
  defp by_harness(id) do
    case WorkingCopies.root(id) do
      {:ok, root} -> ProjectIdentity.resolve(root)
      :unknown -> {:error, {:unknown_harness, id}}
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
        "forward this. Set CMS_DEPLOY_KEY to this project's deploy key, or " <>
        "CMS_TOKEN if you are signed in on this machine."

  defp message({:refused, status}),
    do:
      "The server refused this harness's deploy key with #{status}, so there is " <>
        "no token to forward with. Check CMS_DEPLOY_KEY against the project's " <>
        "deploy key on #{Config.server_url()}."

  defp message({:unreachable, reason}),
    do: "The harness could not reach #{Config.server_url()} to get a token: #{inspect(reason)}"

  defp message({:unknown_harness, id}),
    do:
      "This harness is not serving the working copy #{id}. Either it serves a " <>
        "different set of copies, or this checkout's plugin was generated against " <>
        "an id that has since been reissued — re-run `mix cms.harness.onboard`."

  defp message(:no_harness),
    do:
      "This request does not say which working copy it is about. The MCP " <>
        "server is addressed as /mcp?harness=<id>; run `mix cms.harness.onboard` " <>
        "in the checkout to generate a plugin that sends one."

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
