defmodule CmsHarness.Mcp.ASlowToolCallHoldsUpOnlyItselfTest do
  @moduledoc """
  An agent's tool calls are separate requests: one the server is slow to answer
  holds up only itself.

  Anubis's client sent them one at a time from one process. Main batched two
  `run_script`s and a `check_answer`; the queue passed thirty seconds, the
  client exited, and its engine went down with the turn, four times in three
  minutes (2026-10-12).
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Mcp.Http

  @url "http://cms.test/mcp/harness"

  setup do
    test = self()
    Req.Test.stub(Http, &answer(&1, test))
    :ok
  end

  defp answer(conn, test) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    message = Jason.decode!(body)
    send(test, {:request, message["method"], Plug.Conn.get_req_header(conn, "mcp-session-id")})

    send(
      test,
      {:authorization, message["method"], Plug.Conn.get_req_header(conn, "authorization")}
    )

    respond(conn, message, test)
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _test) do
    conn
    |> Plug.Conn.put_resp_header(
      "mcp-session-id",
      "session-#{System.unique_integer([:positive])}"
    )
    |> json(%{jsonrpc: "2.0", id: id, result: %{protocolVersion: "2025-06-18"}})
  end

  defp respond(conn, %{"method" => "notifications/initialized"}, _test),
    do: Plug.Conn.send_resp(conn, 202, "")

  defp respond(
         conn,
         %{"method" => "tools/call", "id" => id, "params" => %{"name" => name}},
         test
       ),
       do: tool(conn, name, id, test)

  defp tool(conn, "slow", id, test) do
    send(test, {:held, self()})
    receive do: (:release -> :ok)
    event(conn, %{jsonrpc: "2.0", id: id, result: text("slow done")})
  end

  # The first call finds the session gone, as after the server restarted.
  defp tool(conn, "forgotten", id, test), do: forgotten(conn, id, test, Process.get(:forgot))

  defp tool(conn, name, id, _test),
    do: event(conn, %{jsonrpc: "2.0", id: id, result: text("#{name} done")})

  defp forgotten(conn, id, _test, true),
    do: event(conn, %{jsonrpc: "2.0", id: id, result: text("remembered")})

  defp forgotten(conn, _id, test, nil) do
    Process.put(:forgot, true)
    send(test, :forgot)
    Plug.Conn.send_resp(conn, 404, "Session not found")
  end

  defp text(text), do: %{content: [%{type: "text", text: text}]}

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp event(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, "event: message\ndata: #{Jason.encode!(body)}\n\n")
  end

  defp open do
    {:ok, client} = Http.open(@url, %{"authorization" => "Bearer t"}, "2025-06-18")
    assert_received {:request, "initialize", []}
    assert_received {:request, "notifications/initialized", [_session]}
    client
  end

  test "a call answers while another on the same session is still held" do
    client = open()

    slow = Task.async(fn -> Http.call_tool(client, "slow", %{}) end)
    assert_receive {:held, server}, 5_000

    assert {:ok, %{"content" => [%{"text" => "quick done"}]}} =
             Http.call_tool(client, "quick", %{})

    send(server, :release)
    assert {:ok, %{"content" => [%{"text" => "slow done"}]}} = Task.await(slow)
  end

  test "a session the server forgot is opened again and the call answered" do
    client = open()

    assert {:ok, %{"content" => [%{"text" => "remembered"}]}} =
             Http.call_tool(client, "forgotten", %{})

    assert_received :forgot
    assert_received {:request, "initialize", []}
  end

  test "a running agent uses refreshed credentials without reopening its conversation" do
    {:ok, credential} = Agent.start_link(fn -> "old" end)
    provider = fn -> {:ok, %{"authorization" => "Bearer " <> Agent.get(credential, & &1)}} end
    {:ok, client} = Http.open(@url, %{}, "2025-06-18", headers_provider: provider)
    assert_received {:authorization, "initialize", ["Bearer old"]}
    Agent.update(credential, fn _ -> "fresh" end)
    assert {:ok, _} = Http.call_tool(client, "quick", %{})
    assert_received {:authorization, "tools/call", ["Bearer fresh"]}
  end
end
