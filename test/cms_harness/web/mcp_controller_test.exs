defmodule CmsHarness.Web.McpControllerTest do
  @moduledoc """
  The MCP proxy, against a real upstream over a real socket.

  The far side here is a plug on a real port rather than a stub, because
  everything this module does is HTTP: which headers it adds, which it passes
  through, what it does with a status it did not expect, and whether a stream
  actually streams. A stubbed `Req` would assert the shape of a call and prove
  none of that.
  """

  use CmsHarnessTest.ConnCase, async: false

  alias CmsHarnessTest.FakeUpstream

  setup do
    port = FakeUpstream.start!()

    previous_url = Application.get_env(:code_my_spec, :harness_server_url)
    previous_token = Application.get_env(:code_my_spec, :harness_token)
    Application.put_env(:code_my_spec, :harness_server_url, "http://127.0.0.1:#{port}")
    Application.put_env(:code_my_spec, :harness_token, "test-token")

    # The OS environment is cleared by `CmsHarnessTest.ConnCase` — it wins over
    # application config in `CmsHarness.Config`, and `ProjectIdentity` prefers
    # `CMS_PROJECT_ID` over the directory's own config.yml, so a variable
    # exported in someone's shell would decide these tests.
    on_exit(fn ->
      Application.put_env(:code_my_spec, :harness_server_url, previous_url)
      Application.put_env(:code_my_spec, :harness_token, previous_token)
    end)

    :ok
  end

  describe "forwarding" do
    test "a message goes upstream with the credential and the project", %{conn: conn} do
      %{root: dir} = project_dir(project_id: "p-42")
      serve(dir)

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["result"] == %{"ok" => true}

      received = FakeUpstream.last_request()
      assert received.path == "/mcp/harness"
      assert received.headers["authorization"] == "Bearer test-token"
      assert received.headers["x-project-id"] == "p-42"
      assert Jason.decode!(received.body)["method"] == "tools/list"
    end

    # Every test here points `:harness_server_url` at the fake, and that setting
    # is the whole VM's: the harness's own channel clients derive their socket
    # URL from it and redial once a second, so their upgrades land on the fake
    # too. When one landed between the POST and the assertion, `last_request/0`
    # answered about a request no test had made and the file failed on `==`
    # against a path nobody had asked for. Sent by hand here, so the
    # interleaving that used to be a coin flip is the one this test always gets.
    test "a reconnect landing mid-test is not the request under test", %{conn: conn} do
      %{root: dir} = project_dir(project_id: "p-42")
      serve(dir)

      post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      reconnect_upstream()

      assert FakeUpstream.upgrades() >= 1
      assert FakeUpstream.last_request().path == "/mcp/harness"
    end

    test "the session id round-trips in both directions", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)
      FakeUpstream.respond_with(headers: [{"mcp-session-id", "session-from-server"}])

      conn =
        conn
        |> Plug.Conn.put_req_header("mcp-session-id", "session-from-client")
        |> post_rpc(dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert FakeUpstream.last_request().headers["mcp-session-id"] == "session-from-client"
      assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == ["session-from-server"]
    end

    # Plug.Parsers stores a top-level JSON array under `_json`. Forwarding the
    # wrapper would send the server an object it cannot parse as a batch.
    test "a batch is forwarded as an array, not as the parser's wrapper", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)

      batch = [
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"},
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}
      ]

      # Encoded by hand: the test adapter builds params from a map, and a
      # top-level array is exactly what this is about.
      post_rpc(conn, dir, Jason.encode!(batch))

      assert [%{"id" => 1}, %{"id" => 2}] = Jason.decode!(FakeUpstream.last_request().body)
    end

    test "an upstream refusal arrives as itself, not as a harness error", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)
      FakeUpstream.respond_with(status: 401, body: ~s({"error":"invalid_token"}))

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
    end

    # A wedged dev server answers every request with Phoenix's styled
    # `CompileError` page — 30KB of markup and a base64 SVG logo. Relayed
    # verbatim, that arrived in an agent's context as the result of
    # `create_issue`: the tool for reporting friction failing by consuming the
    # context needed to report it (5fb011f4, 6ecb257a).
    test "an HTML error page is summarized, not relayed", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)

      page =
        "<!DOCTYPE html>\n<html><body><div>** (RuntimeError) could not compile " <>
          "application: code_my_spec. You must restart your server after changing " <>
          "configuration files</div>" <> String.duplicate("<span>padding</span>", 2_000) <>
          "</body></html>"

      FakeUpstream.respond_with(status: 500, body: page, headers: [{"content-type", "text/html"}])

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call"})

      body = Jason.decode!(conn.resp_body)

      assert body["error"]["message"] =~ "error page",
             "the agent has to be told what happened, not shown the document"

      assert body["error"]["message"] =~ "config",
             "the recovery is the useful part: this server needs dealing with"

      assert body["id"] == 7, "a JSON-RPC error still has to answer the request it failed"

      refute conn.resp_body =~ "<!DOCTYPE",
             "relaying the page is the defect — 30KB of markup into an agent's context"

      assert byte_size(conn.resp_body) < 1_000,
             "a summary that is not short has not solved the problem it exists for"
    end

    # The same page, rendered as markdown rather than HTML.
    #
    # Phoenix's debug page follows what the request accepts, and the MCP client
    # sends `application/json, text/event-stream` — so it is not always markup.
    # A `Phoenix.Ecto.PendingMigrationError` came back this way, sailed past a
    # check that only looked for HTML, and reached the agent as a raw stack
    # trace. Recognising the exception marker catches both renderings.
    test "a non-HTML error page is summarized too", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)

      page =
        "# Phoenix.Ecto.PendingMigrationError at POST /mcp/harness\n\n" <>
          "Exception:\n\n    ** (Phoenix.Ecto.PendingMigrationError) there are " <>
          "pending migrations for repo: CodeMySpec.Repo\n" <>
          String.duplicate("        (stdlib 7.1) gen_server.erl:2424\n", 200)

      FakeUpstream.respond_with(
        status: 500,
        body: page,
        headers: [{"content-type", "text/markdown"}]
      )

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/call"})
      body = Jason.decode!(conn.resp_body)

      assert body["error"]["message"] =~ "error page",
             "an error page is an error page whatever it is rendered as"

      assert body["error"]["message"] =~ "migration",
             "the exception is the useful part and it survived the summary"

      assert body["id"] == 9

      assert byte_size(conn.resp_body) < 1_000,
             "the stack trace is what must not reach the agent"
    end

    # The guard keys on HTML specifically. An SSE body is the server→client
    # channel and a JSON body is a result; treating "not JSON" as broken would
    # take out streaming, which is the more expensive mistake.
    test "a non-JSON stream body is still relayed", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)

      FakeUpstream.respond_with(
        status: 200,
        body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1}\n\n",
        headers: [{"content-type", "text/event-stream"}]
      )

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert conn.status == 200
      assert conn.resp_body =~ "event: message"
    end

    test "DELETE ends the session upstream", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)

      conn
      |> Plug.Conn.put_req_header("mcp-session-id", "doomed")
      |> delete("/mcp?harness=#{harness_id_at(dir)}")

      assert FakeUpstream.last_request().method == "DELETE"
      assert FakeUpstream.last_request().headers["mcp-session-id"] == "doomed"
    end
  end

  describe "the server→client stream" do
    test "chunks are relayed as they arrive", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)
      FakeUpstream.stream(["event: message\ndata: one\n\n", "event: message\ndata: two\n\n"])

      conn =
        conn
        |> Plug.Conn.put_req_header("accept", "text/event-stream")
        |> get("/mcp?harness=#{harness_id_at(dir)}")

      assert conn.status == 200
      assert conn.resp_body =~ "data: one"
      assert conn.resp_body =~ "data: two"
      assert FakeUpstream.last_request().method == "GET"
    end

    # A stream opened before the status is known would have committed to 200,
    # and Claude Code would sit on an empty channel instead of being told its
    # token is bad.
    test "a refusal is a refusal, not an empty stream", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)
      FakeUpstream.respond_with(status: 401, body: ~s({"error":"invalid_token"}))

      conn =
        conn
        |> Plug.Conn.put_req_header("accept", "text/event-stream")
        |> get("/mcp?harness=#{harness_id_at(dir)}")

      assert conn.status == 401
      assert conn.resp_body =~ "invalid_token"
    end
  end

  # `require_oauth_token` on the server takes a user's access token and nothing
  # else, so a sprite — which holds a project deploy key and no user — has to
  # trade first. See `CmsHarness.Token`.
  describe "a harness holding only a deploy key" do
    setup do
      Application.delete_env(:code_my_spec, :harness_token)
      Application.put_env(:code_my_spec, :harness_deploy_key, "a-deploy-key")
      CmsHarness.Token.invalidate()

      on_exit(fn ->
        Application.delete_env(:code_my_spec, :harness_deploy_key)
        CmsHarness.Token.invalidate()
      end)
    end

    test "trades it for a token and forwards with that", %{conn: conn} do
      %{root: dir} = project_dir(project_id: "p-9")
      serve(dir)

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert conn.status == 200

      exchange = FakeUpstream.last_exchange()
      assert exchange.method == "POST"
      assert exchange.headers["authorization"] == "Bearer a-deploy-key"

      # The deploy key itself never reaches the tool surface — that is the
      # whole point of exchanging rather than widening it.
      forwarded = FakeUpstream.last_request()
      assert forwarded.path == "/mcp/harness"
      assert forwarded.headers["authorization"] == "Bearer exchanged-token"
    end

    test "the token is reused rather than re-bought on every call", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)

      post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      first = FakeUpstream.last_exchange()

      :persistent_term.put({FakeUpstream, :exchange}, nil)
      post_rpc(build_conn(), dir, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

      assert first != nil
      assert FakeUpstream.last_exchange() == nil
    end

    # A token about to expire is re-bought before it is presented: one that
    # expires between the check and the request arrives as a 401 the caller
    # cannot explain.
    test "a token inside the refresh margin is re-bought", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)
      FakeUpstream.exchange_answers(:ok, expires_in: 60)

      post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      :persistent_term.put({FakeUpstream, :exchange}, nil)

      post_rpc(build_conn(), dir, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

      assert FakeUpstream.last_exchange() != nil
    end

    test "a refused key says so rather than forwarding without one", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)
      FakeUpstream.exchange_answers(401)

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      message = Jason.decode!(conn.resp_body)["error"]["message"]
      assert message =~ "401"
      assert message =~ "CMS_DEPLOY_KEY"
      assert FakeUpstream.last_request().path == "/api/sprite/token"
    end
  end

  describe "refusing" do
    test "with no credential it says so instead of forwarding", %{conn: conn} do
      Application.delete_env(:code_my_spec, :harness_token)
      %{root: dir} = project_dir()
      serve(dir)

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"})

      # 200 with a JSON-RPC error, not an HTTP error: the client is an MCP
      # transport, and a bare 400 reads as "the server is broken".
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == 7
      assert body["error"]["message"] =~ "CMS_DEPLOY_KEY"
      assert FakeUpstream.last_request() == nil
    end

    test "naming no working copy is refused, not guessed at", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "?harness="
      assert FakeUpstream.last_request() == nil
    end

    test "an id this harness does not serve names the id", %{conn: conn} do
      gone = Ecto.UUID.generate()

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/mcp?harness=#{gone}", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ gone

      assert FakeUpstream.last_request_to("/mcp/harness") == nil,
             "the harness asked the server where that copy is and was told nothing, " <>
               "so it forwarded no session — asking is not forwarding"
    end

    test "an unreachable server says which one", %{conn: conn} do
      Application.put_env(:code_my_spec, :harness_server_url, "http://127.0.0.1:1")
      %{root: dir} = project_dir()
      serve(dir)

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "http://127.0.0.1:1"
    end
  end

  # The request a channel client makes when it reconnects, byte for byte as far
  # as the fake can tell: it sees an upgrade, and has no idea who dialled it.
  defp reconnect_upstream do
    Req.get(
      url: Application.get_env(:code_my_spec, :harness_server_url) <> "/socket/websocket",
      headers: [{"upgrade", "websocket"}, {"connection", "upgrade"}],
      retry: false
    )
  end

  defp post_rpc(conn, dir, payload) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/mcp?harness=#{harness_id_at(dir)}", payload)
  end
end
