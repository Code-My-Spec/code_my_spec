defmodule CmsHarness.Web.McpController do
  @moduledoc """
  The MCP surface, forwarded to the server.

  The light harness has no tools of its own; it is a `localhost` URL Claude
  Code will talk to over plain HTTP. Whole JSON-RPC messages are forwarded at
  the transport layer with no knowledge of the tools, so a new tool never needs
  adding here.

  ## What it adds

    * `Authorization: Bearer <token>` from `CmsHarness.Token.access_token/1`:
      `/mcp/harness` takes only OAuth access tokens, so a deploy key is
      exchanged first.
    * `X-Project-ID`, resolved through the working copy's id
      (`ProjectIdentity.resolve/1`, no database).
    * `X-Harness-Id`: the session is addressed by working copy, never by
      directory or project, so two checkouts of one project hold two sessions.

  Tool names stay `mcp__plugin_codemyspec_local__*`.
  See knowledge/harness, "MCP proxy".
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.HarnessConfig
  alias CmsHarness.ProjectIdentity
  alias CmsHarness.Token
  alias CmsHarness.Web.UpstreamError
  alias CmsHarness.WorkingCopies
  alias Req.Request

  # Request headers that mean something to the far end. `authorization` is
  # absent: this adds its own. `x-agent-id` is verified server-side
  # (`AgentScope`) and must not be dropped — without it an agent's questions
  # route straight to the person.
  @forwarded ~w(accept content-type mcp-session-id mcp-protocol-version last-event-id
                x-agent-id)

  @doc """
  Request headers this proxy passes through to the server.

  Public because it is a contract: a header absent from this list is dropped
  silently.
  """
  @spec forwarded_headers() :: [String.t()]
  def forwarded_headers, do: @forwarded

  # What the far end sends back that the client's transport reads. Content type
  # is set separately because Phoenix owns it on the conn.
  @returned ~w(mcp-session-id mcp-protocol-version)

  # A POST is one request and one answer; Anubis always replies JSON to it.
  # Main's bash in a named copy (`CodeMySpec.CopyTools`) may run for its full
  # hour, so the relay waits past that rather than cutting the answer off.
  @post_timeout to_timeout(hour: 1, minute: 1)

  def proxy(conn, _params) do
    with {:ok, project} <- project(conn),
         {:ok, token} <- Token.access_token(project.root) do
      dispatch(conn, project, token)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # GET is the server→client channel: long-lived, and streamed. `into: fun`,
  # not `into: :self`, whose async enumerable raises when the upstream dies
  # mid-stream; `into: fun` returns the exception for `finish_stream/2`.
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

  # An HTML error page (a wedged dev server) is never a tool result, so it is
  # summarized as a JSON-RPC error rather than relayed into an agent's context.
  # JSON and SSE pass through.
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
      # Relayed verbatim; a re-encode could change something.
      decode_body: false,
      # Claude Code retries; a second layer multiplies slow calls.
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

    # The harness id travels too: two checkouts share one `x-project-id`.
    [
      {"authorization", "Bearer " <> token},
      {"x-project-id", project.id}
      | harness_header(conn) ++ forwarded
    ]
  end

  # Path first (`/api/harnesses/<id>/mcp`: survives proxies and redirects,
  # shows in access logs), then `?harness=` (the released plugin sends it),
  # then `?dir=`, then the `x-harness-id` header.
  defp working_copy_id(conn) do
    conn.path_params["working_copy_id"] || conn.path_params["harness_id"] ||
      conn.query_params["harness"] ||
      id_from_dir(conn.query_params["dir"]) ||
      List.first(get_req_header(conn, "x-harness-id"))
  end

  # A directory the caller sits in beats a header it inherited: the header is
  # interpolated from `${CMS_HARNESS_ID}` in the ambient environment, which a
  # worktree session inherits from its parent. Resolved locally; only the id
  # goes on to the server. See knowledge/harness, "MCP proxy".
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

  # `conn.body_params`, re-encoded (Plug.Parsers consumed the raw body). A batch
  # arrives under `_json` and is unwrapped.
  defp body(conn) do
    case conn.body_params do
      %{"_json" => batch} -> Jason.encode!(batch)
      params -> Jason.encode!(params)
    end
  end

  # The status is final before any `:data`, so an upstream 401 reaches the
  # client as a 401. A 200 streams chunk by chunk; any other status is buffered
  # and sent whole by `finish_stream/2`.
  defp relay_chunk({:data, data}, {request, %{status: 200} = resp}) do
    %{conn: conn, chunking?: chunking?} = state = Request.get_private(request, :cms_relay)
    conn = if chunking?, do: conn, else: begin_event_stream(conn, resp)

    case chunk(conn, data) do
      {:ok, conn} ->
        {:cont, {put_relay(request, %{state | conn: conn, chunking?: true}), resp}}

      # The agent went away: a normal end, not logged. Halt pulling upstream.
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

  # `run_request/1` answers a response or an exception, never a raise.
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

  # Upstream died after chunks were sent: end the stream silently.
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

  # The working copy id, from any of `working_copy_id/1`'s sources.
  defp project(conn) do
    case working_copy_id(conn) do
      id when is_binary(id) and id != "" -> by_harness(id)
      _ -> {:error, :no_harness}
    end
  end

  # The id resolves to a root (asking the server if need be), then a project.
  defp by_harness(id) do
    case WorkingCopies.root(id) do
      {:ok, root} -> ProjectIdentity.resolve(root)
      :unknown -> {:error, {:unknown_harness, id}}
      {:unreachable, reason} -> {:error, {:server_unreachable, id, reason}}
    end
  end

  # A JSON-RPC error, not an HTTP one, so the agent sees which failure it was.
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

  Public because it is the whole of what the agent sees; testable without a
  conn.
  """
  def message(:no_credential),
    do:
      "The CodeMySpec harness has no credential for the server, so it cannot " <>
        "forward this. Run /codemyspec:init, which shows the sign-in code to approve."

  def message({:refused, status}),
    do:
      "The server refused this harness's deploy key with #{status}, so there is " <>
        "no token to forward with. Check the deploy key in this copy's " <>
        ".cms_harness.json against the project's deploy key on #{Config.server_url()}." <>
        unavailable_hint({:refused, status})

  def message({:unreachable, reason}),
    do: "The harness could not reach #{Config.server_url()} to get a token: #{inspect(reason)}"

  def message({:unknown_harness, id}),
    do:
      "This harness is not serving the working copy #{id}. Either it serves a " <>
        "different set of copies, or this checkout's plugin was generated against " <>
        "an id that has since been reissued — re-run `mix cms.harness.onboard`."

  # Nobody got to ask, so the id is not implicated.
  def message({:server_unreachable, id, reason}),
    do:
      "The harness could not reach #{Config.server_url()} to find out where #{id} " <>
        "is: #{inspect(reason, limit: 5)}. Nothing is wrong with the id and " <>
        "re-onboarding will not help — the server is down or unreachable from here." <>
        unavailable_hint(reason)

  def message(:no_harness),
    do:
      "This request does not say which working copy it is about. The MCP " <>
        "server is addressed as /mcp?harness=<id> or by `X-Harness-Id`; the plugin " <>
        "sends `?dir=${CLAUDE_PROJECT_DIR}`, resolved through that directory's " <>
        "`.cms_harness.json`. Run /codemyspec:init there if it is missing."

  def message(:no_project_id),
    do:
      "This directory does not say which project it is: neither " <>
        ".code_my_spec/config.yml nor .cms_harness.json names a `project_id`."

  def message(:restarting),
    do: "The harness is restarting (a promote restarts it). Call again in a few seconds."

  def message(:unreadable_config),
    do: "The harness could not read .code_my_spec/config.yml in this directory."

  def message({:invalid_config, reason}),
    do: "The harness could not parse .code_my_spec/config.yml: #{inspect(reason)}"

  def message(reason), do: "The CodeMySpec harness could not forward this: #{inspect(reason)}"

  # A 503 is a server refusing everything, usually
  # `Phoenix.Ecto.CheckRepoStatus` on a pending migration. A hint, not a
  # diagnosis: the harness cannot see the body.
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
