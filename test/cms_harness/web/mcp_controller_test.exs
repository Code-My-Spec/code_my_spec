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

    # The environment wins over application config in `CmsHarness.Config`, so a
    # developer with CMS_TOKEN exported would otherwise have the suite forward
    # to their real server with their real credential.
    #
    # CMS_PROJECT_ID for the same reason and a sharper one: `ProjectIdentity`
    # prefers it over the directory's own config.yml, so with it set every test
    # here passed while proving nothing about resolution. `envs/.env` sets it.
    saved =
      Enum.map(
        ~w(CMS_SERVER_URL CMS_TOKEN CMS_DEPLOY_KEY CMS_PROJECT_ID CMS_PROJECT_DIR),
        &{&1, System.get_env(&1)}
      )

    Enum.each(saved, fn {name, _} -> System.delete_env(name) end)

    on_exit(fn ->
      Enum.each(saved, fn
        {_name, nil} -> :ok
        {name, value} -> System.put_env(name, value)
      end)

      Application.put_env(:code_my_spec, :harness_server_url, previous_url)
      Application.put_env(:code_my_spec, :harness_token, previous_token)
    end)

    :ok
  end

  describe "forwarding" do
    test "a message goes upstream with the credential and the project", %{conn: conn} do
      %{root: dir} = project_dir(project_id: "p-42")

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
      FakeUpstream.respond_with(status: 401, body: ~s({"error":"invalid_token"}))

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
    end

    test "DELETE ends the session upstream", %{conn: conn} do
      %{root: dir} = project_dir()

      conn
      |> Plug.Conn.put_req_header("mcp-session-id", "doomed")
      |> delete("/mcp?dir=#{URI.encode_www_form(dir)}")

      assert FakeUpstream.last_request().method == "DELETE"
      assert FakeUpstream.last_request().headers["mcp-session-id"] == "doomed"
    end
  end

  describe "the server→client stream" do
    test "chunks are relayed as they arrive", %{conn: conn} do
      %{root: dir} = project_dir()
      FakeUpstream.stream(["event: message\ndata: one\n\n", "event: message\ndata: two\n\n"])

      conn =
        conn
        |> Plug.Conn.put_req_header("accept", "text/event-stream")
        |> get("/mcp?dir=#{URI.encode_www_form(dir)}")

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
      FakeUpstream.respond_with(status: 401, body: ~s({"error":"invalid_token"}))

      conn =
        conn
        |> Plug.Conn.put_req_header("accept", "text/event-stream")
        |> get("/mcp?dir=#{URI.encode_www_form(dir)}")

      assert conn.status == 401
      assert conn.resp_body =~ "invalid_token"
    end
  end

  describe "refusing" do
    test "with no credential it says so instead of forwarding", %{conn: conn} do
      Application.delete_env(:code_my_spec, :harness_token)
      %{root: dir} = project_dir()

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"})

      # 200 with a JSON-RPC error, not an HTTP error: the client is an MCP
      # transport, and a bare 400 reads as "the server is broken".
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == 7
      assert body["error"]["message"] =~ "CMS_TOKEN"
      assert FakeUpstream.last_request() == nil
    end

    test "with no working directory it names the parameter the plugin sends", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "?dir="
      assert FakeUpstream.last_request() == nil
    end

    test "a directory that cannot say which project it is names the file", %{conn: conn} do
      dir =
        Path.join(System.tmp_dir!(), "cms_harness_no_id_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ ".code_my_spec/config.yml"
      assert FakeUpstream.last_request() == nil
    end

    test "an unreachable server says which one", %{conn: conn} do
      Application.put_env(:code_my_spec, :harness_server_url, "http://127.0.0.1:1")
      %{root: dir} = project_dir()

      conn = post_rpc(conn, dir, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "http://127.0.0.1:1"
    end
  end

  defp post_rpc(conn, dir, payload) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/mcp?dir=#{URI.encode_www_form(dir)}", payload)
  end
end
