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

  alias CmsHarness.HarnessConfig
  alias CmsHarness.Config
  alias CmsHarness.ProjectIdentity
  alias CmsHarness.Token
  alias CmsHarness.Web.UpstreamError
  alias CmsHarness.WorkingCopies
  alias Req.Request

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
         {:ok, token} <- Token.access_token(project.root) do
      dispatch(conn, project, token)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # GET is the server→client channel: long-lived, and the only way a
  # server-initiated request (`ask_user`, elicitation) reaches the agent. It is
  # streamed rather than buffered, because buffering it would mean the agent
  # never sees anything until the session ends.
  #
  # `into: fun` rather than `into: :self`: the latter's `Req.Response.Async`
  # raises out of `Enum.reduce_while/3` the moment the upstream connection
  # dies mid-stream (`Enumerable.Req.Response.Async.reduce/3` does `raise e`
  # on a transport error, not `{:error, e}`) — and that crossed `action/2`
  # unhandled, taking the whole request down for a session that had already
  # gotten a real 200 and real chunks. `into: fun` reports the same failure as
  # `run_request/1`'s ordinary return, `Exception.t()` instead of
  # `Req.Response.t()` — see `finish_stream/2` — so it is handled the same way
  # every other upstream outcome here is: matched, not rescued.
  defp dispatch(%{method: "GET"} = conn, project, token) do
    req =
      request(conn, project, token, :get, nil, :infinity)
      |> Req.merge(into: &relay_chunk/2)
      |> Request.put_private(:cms_relay, %{conn: conn, chunking?: false, buffer: []})

    {req, result} = Request.run_request(req)
    finish_stream(result, Request.get_private(req, :cms_relay))
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
    do:
      UpstreamError.summary(
        to_string(response.body || ""),
        response.status,
        content_type(response)
      )

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

  # Path first, then the query, then the header.
  #
  # The path is the address: `/api/harnesses/<id>/mcp`, which is how the hooks
  # have always been addressed and what makes two checkouts of one project two
  # sessions. Identity in the path cannot be dropped by a proxy that strips
  # unknown headers, survives a redirect, and shows up in every access log — a
  # query string does the first two and a header does none of them.
  #
  # The other two remain because the released marketplace plugin sends
  # `?harness=<id>` and nothing can change that until it ships again; refusing
  # them would take MCP down on every machine running the release. They are
  # older spellings of one address, not alternatives to it.
  defp working_copy_id(conn) do
    conn.path_params["working_copy_id"] || conn.path_params["harness_id"] ||
      conn.query_params["harness"] ||
      id_from_dir(conn.query_params["dir"]) ||
      List.first(get_req_header(conn, "x-harness-id"))
  end

  # A directory the caller is actually sitting in beats a header it inherited.
  #
  # `x-harness-id` reaches us from `plugin.json`'s
  # `headers: {"X-Harness-Id": "${CMS_HARNESS_ID}"}`, and an `mcpServers` entry
  # interpolates the *ambient* environment. A Claude Code session spawned for a
  # worktree inherits its parent's environment wholesale — measured on this
  # machine: a session in `.claude/worktrees/phx-new-generator` carried the main
  # checkout's `CMS_HARNESS_ID` (and its `MIX_TEST_PARTITION`), so every MCP call
  # it made was attributed to main. Files it had written were invisible, and a
  # requirement insisting an implementation file was missing was answering about
  # a different checkout, with nothing anywhere reporting the disagreement.
  #
  # This is the same bug `HarnessConfig.read/1` already refuses one layer in —
  # its comment names the same value, `6c4a7be3`, for the same reason. The
  # daemon stopped trusting the environment; the client had not.
  #
  # The directory travels client to local harness only, and is resolved here
  # against that checkout's own `.cms_harness.json`. What goes on to the server
  # is still an id and nothing else, so "harness id is the only routing key"
  # holds where it was meant to: on the wire to the server.
  #
  # Below the addressed forms, because an explicit id is a caller saying which
  # copy it means; above the header, which is a caller repeating whatever its
  # parent's shell happened to hold.
  defp id_from_dir(dir) when is_binary(dir) and dir != "" do
    case HarnessConfig.read(dir) do
      {:ok, %{working_copy_id: id}} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp id_from_dir(_), do: nil

  defp harness_header(conn) do
    case working_copy_id(conn) do
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

  # The status has to be known before anything is sent to the client: an
  # upstream 401 must reach it as a 401, and a stream opened optimistically
  # would have already committed to 200. `status`/`headers` events land on
  # `resp` before any `:data` can (HTTP always sends them first), so by the
  # time this runs at all the accumulator's `resp.status` is already final.
  #
  # A 200's chunks are written straight to the client as they arrive. Any
  # other status is never streamed — its bytes are only ever a small error
  # body — so they are held in `state.buffer` and sent as one plain response
  # once the whole thing is known, in `finish_stream/2`.
  defp relay_chunk({:data, data}, {request, %{status: 200} = resp}) do
    %{conn: conn, chunking?: chunking?} = state = Request.get_private(request, :cms_relay)
    conn = if chunking?, do: conn, else: begin_event_stream(conn, resp)

    case chunk(conn, data) do
      {:ok, conn} ->
        {:cont, {put_relay(request, %{state | conn: conn, chunking?: true}), resp}}

      # The agent went away. Nothing to log: closing the tab is the normal end
      # of an MCP session, not a fault. Halting tells Finch to stop pulling
      # more of the upstream body — there is nowhere left to put it.
      {:error, _reason} ->
        {:halt, {put_relay(request, %{state | conn: conn, chunking?: true}), resp}}
    end
  end

  defp relay_chunk({:data, data}, {request, resp}) do
    state = Request.get_private(request, :cms_relay)
    {:cont, {put_relay(request, %{state | buffer: [state.buffer, data]}), resp}}
  end

  defp put_relay(request, state), do: Request.put_private(request, :cms_relay, state)

  defp begin_event_stream(conn, response) do
    conn
    |> copy_headers(response)
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  # `run_request/1` always answers with one of these — a response or an
  # `Exception.t()`, never a raise (see `dispatch/3`'s GET clause) — so the
  # upstream connection dying mid-stream is just one more shape to match, the
  # same as it dying before anything came back at all.
  defp finish_stream(%Req.Response{status: 200}, %{chunking?: true, conn: conn}), do: conn

  defp finish_stream(%Req.Response{status: 200} = response, %{chunking?: false, conn: conn}),
    do: begin_event_stream(conn, response)

  defp finish_stream(%Req.Response{} = response, %{conn: conn, buffer: buffer}) do
    Logger.warning("[CmsHarness] MCP stream refused upstream: #{response.status}")

    conn
    |> copy_headers(response)
    |> put_resp_content_type(content_type(response))
    |> send_resp(response.status, IO.iodata_to_binary(buffer))
  end

  # Chunking had already started: a real 200 and real chunks already reached
  # the client, so the upstream dying now ends the stream the same way the
  # agent's own disconnect does above — silently, by sending no more.
  defp finish_stream(exception, %{chunking?: true, conn: conn}) when is_exception(exception),
    do: conn

  defp finish_stream(exception, %{conn: conn}) when is_exception(exception),
    do: unreachable(conn, exception)

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
    case working_copy_id(conn) do
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
      {:unreachable, reason} -> {:error, {:server_unreachable, id, reason}}
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

  @doc """
  The sentence an agent gets when the harness cannot forward its call.

  Public because it is the whole of what the agent sees and it carries real
  judgement — five different failures arrive here and the wrong wording sends
  the reader after the wrong thing. Testable without building a conn.
  """
  def message(:no_credential),
    do:
      "The CodeMySpec harness has no credential for the server, so it cannot " <>
        "forward this. Set CMS_DEPLOY_KEY to this project's deploy key, or " <>
        "CMS_TOKEN if you are signed in on this machine."

  def message({:refused, status}),
    do:
      "The server refused this harness's deploy key with #{status}, so there is " <>
        "no token to forward with. Check CMS_DEPLOY_KEY against the project's " <>
        "deploy key on #{Config.server_url()}." <> unavailable_hint({:refused, status})

  def message({:unreachable, reason}),
    do: "The harness could not reach #{Config.server_url()} to get a token: #{inspect(reason)}"

  def message({:unknown_harness, id}),
    do:
      "This harness is not serving the working copy #{id}. Either it serves a " <>
        "different set of copies, or this checkout's plugin was generated against " <>
        "an id that has since been reissued — re-run `mix cms.harness.onboard`."

  # Distinct from the clause above, where the server answered and said no. Here
  # nobody got to ask, so the id is not implicated and onboarding is not the fix.
  def message({:server_unreachable, id, reason}),
    do:
      "The harness could not reach #{Config.server_url()} to find out where #{id} " <>
        "is: #{inspect(reason, limit: 5)}. Nothing is wrong with the id and " <>
        "re-onboarding will not help — the server is down or unreachable from here." <>
        unavailable_hint(reason)

  def message(:no_harness),
    do:
      "This request does not say which working copy it is about. The MCP " <>
        "server is addressed as /mcp?harness=<id>; run `mix cms.harness.onboard` " <>
        "in the checkout to generate a plugin that sends one."

  def message(:no_project_id),
    do:
      "This directory does not say which project it is. Put a `project_id` in " <>
        ".code_my_spec/config.yml, or set CMS_PROJECT_ID."

  def message(:unreadable_config),
    do: "The harness could not read .code_my_spec/config.yml in this directory."

  def message({:invalid_config, reason}),
    do: "The harness could not parse .code_my_spec/config.yml: #{inspect(reason)}"

  def message(reason), do: "The CodeMySpec harness could not forward this: #{inspect(reason)}"

  # A 503 is not "unreachable". The server answered — it is up and refusing
  # everything — and on this stack there is one overwhelming reason for that.
  #
  # `Phoenix.Ecto.CheckRepoStatus` refuses every request with
  # `PendingMigrationError` while the dev database is behind. Since :4000 serves
  # the MCP endpoint, every agent on the machine loses every tool at the same
  # moment, and the message they get names a harness id — which is the one thing
  # that is definitely fine. Measured: an agent committed a migration from a
  # worktree, ran it against its own test partition, pushed, and nothing ran it
  # on dev. The reason was visible only in `web.log`, behind a 4KB `conn` dump.
  #
  # A hint rather than a diagnosis: the harness cannot see the body, so this
  # says what to check first, not what is wrong. `7d1bde0e`.
  defp unavailable_hint(reason) do
    if service_unavailable?(reason) do
      "\n\nA 503 means the server is up and refusing every request. The usual " <>
        "cause here is a pending migration — `Phoenix.Ecto.CheckRepoStatus` " <>
        "refuses everything while the dev database is behind, and a migration " <>
        "committed from a worktree is only ever run against that worktree's test " <>
        "database. Check with `mix ecto.migrate` in the main checkout, or " <>
        "`just refresh`, which now does it. The reason is in ~/.codemyspec/web.log."
    else
      ""
    end
  end

  defp service_unavailable?({:refused, 503}), do: true
  defp service_unavailable?({:error, inner}), do: service_unavailable?(inner)
  defp service_unavailable?(_), do: false

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
