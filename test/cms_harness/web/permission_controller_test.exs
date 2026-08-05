defmodule CmsHarness.Web.PermissionControllerTest do
  @moduledoc """
  The permission proxy, against a real upstream on a real port.

  One property carries the rest: **no failure may become an approval.** A proxy
  standing between an agent and a permission prompt that answers "allow" when it
  could not reach anybody has done the one thing it exists to prevent, and it
  does it silently. Every test here is that property from a different angle —
  no credential, no server, a server that refuses, nobody answering — and each
  asserts `"ask"`, which puts Claude Code's own prompt in front of whoever is
  at the terminal.
  """

  use CmsHarnessTest.ConnCase, async: false

  alias CmsHarnessTest.FakeUpstream

  setup do
    port = FakeUpstream.start!()

    previous_url = Application.get_env(:code_my_spec, :harness_server_url)
    previous_token = Application.get_env(:code_my_spec, :harness_token)
    Application.put_env(:code_my_spec, :harness_server_url, "http://127.0.0.1:#{port}")
    Application.put_env(:code_my_spec, :harness_token, "test-token")

    saved = Enum.map(~w(CMS_SERVER_URL CMS_TOKEN CMS_DEPLOY_KEY), &{&1, System.get_env(&1)})
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

  test "the request reaches the server as the person who can answer it", %{conn: conn} do
    FakeUpstream.respond_with(status: 201, body: ~s({"id":"req-1"}))

    # 1ms rather than the two-minute default: what is asserted is what was sent,
    # and nothing in this test is going to answer.
    request(conn, %{"tool_name" => "Bash", "tool_input" => %{"command" => "rm -rf /"}})

    # `last_request_to/1`, not `last_request/0`: the proxy raises the request
    # over HTTP and then opens a websocket for the answer, so the socket upgrade
    # is what arrived last.
    received = FakeUpstream.last_request_to("/api/permissions/request")
    assert received.headers["authorization"] == "Bearer test-token"

    body = Jason.decode!(received.body)
    assert body["tool_name"] == "Bash"
    assert body["tool_input"] == %{"command" => "rm -rf /"}
  end

  describe "every way this fails, it asks" do
    test "when nobody answers in time", %{conn: conn} do
      FakeUpstream.respond_with(status: 201, body: ~s({"id":"req-1"}))

      conn = request(conn, %{"tool_name" => "Bash"})

      assert behavior(conn) == "ask"
    end

    test "when the server refuses to raise the request", %{conn: conn} do
      FakeUpstream.respond_with(status: 422, body: ~s({"error":"nope"}))

      assert behavior(request(conn, %{"tool_name" => "Bash"})) == "ask"
    end

    test "when the server is not there at all", %{conn: conn} do
      Application.put_env(:code_my_spec, :harness_server_url, "http://127.0.0.1:1")

      assert behavior(request(conn, %{"tool_name" => "Bash"})) == "ask"
    end

    test "when the harness has no credential", %{conn: conn} do
      Application.delete_env(:code_my_spec, :harness_token)

      assert behavior(request(conn, %{"tool_name" => "Bash"})) == "ask"
      assert FakeUpstream.last_request() == nil
    end
  end

  # A request naming no tool is the caller's mistake, not a decision to make.
  test "a request with no tool_name is refused rather than answered", %{conn: conn} do
    conn = request(conn, %{"tool_input" => %{}})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "tool_name"
    assert FakeUpstream.last_request() == nil
  end

  test "the hook response is the shape Claude Code reads", %{conn: conn} do
    FakeUpstream.respond_with(status: 201, body: ~s({"id":"req-1"}))

    body = Jason.decode!(request(conn, %{"tool_name" => "Bash"}).resp_body)

    assert %{
             "hookSpecificOutput" => %{
               "hookEventName" => "PermissionRequest",
               "decision" => %{"behavior" => "ask"}
             }
           } = body
  end

  defp request(conn, payload) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/permissions/request", Map.put_new(payload, "timeout", 1))
  end

  defp behavior(conn) do
    Jason.decode!(conn.resp_body)["hookSpecificOutput"]["decision"]["behavior"]
  end
end
