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

    test "DELETE ends the session upstream", %{conn: conn} do
      %{root: dir} = project_dir()
      serve(dir)

      conn
      |> Plug.Conn.put_req_header("mcp-session-id", "doomed")
      |> delete("/mcp?harness=#{harness_id_at(dir)}")

      # The DELETE specifically, not whatever reached the server most recently.
      # The harness reconnects and retries on its own schedule, so "the last
      # request" is not something this test controls.
      deletion = FakeUpstream.last_request_with_method("DELETE")

      assert deletion, "no DELETE reached the upstream"
      assert deletion.headers["mcp-session-id"] == "doomed"
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

  defp post_rpc(conn, dir, payload) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/mcp?harness=#{harness_id_at(dir)}", payload)
  end
end
