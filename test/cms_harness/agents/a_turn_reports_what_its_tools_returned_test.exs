defmodule CmsHarness.Agents.ATurnReportsWhatItsToolsReturnedTest do
  @moduledoc """
  What the conversation page shows of a turn that calls tools, which Alloy's
  own events leave out (`TurnEvents`): each call's result on its `:tool_end`,
  and what the model said alongside the calls it asked for. And a call to a
  tool the agent does not carry is told where it is (`UnknownTool`).
  """
  use ExUnit.Case, async: true

  alias CmsHarnessTest.Machine
  alias Plug.Conn

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    Machine.ensure_supervisor()
    id = "turn-events-#{System.unique_integer([:positive])}"
    test_pid = self()

    {:ok, _} =
      Machine.start_agent(id, root,
        provider: "anthropic",
        api_key: "unused",
        req_options: [plug: provider(test_pid)],
        on_event: fn _agent_id, envelope -> send(test_pid, {:event, envelope}) end
      )

    on_exit(fn -> Machine.stop_agent(id) end)
    {:ok, :started} = Machine.send_message(id, "ref-1", "file an issue")
    assert_receive {:event, %{event: :turn_ended}}, 10_000
    :ok
  end

  test "a tool call's result is on its tool_end" do
    assert_received {:event, %{event: :tool_end, payload: %{name: "create_issue"} = payload}}
    assert payload.result =~ "call it from run_script"
  end

  test "what the model said alongside its calls is a message of its own" do
    assert_received {:event, %{event: :assistant_message, payload: %{text: "Let me file it."}}}
  end

  test "a call to a tool the agent does not carry is told where it is reachable" do
    assert_received {:second_request, body}

    [result] =
      for %{"role" => "user", "content" => blocks} when is_list(blocks) <- body["messages"],
          %{"type" => "tool_result"} = block <- blocks,
          do: block

    assert inspect(result["content"]) =~ "call it from run_script"
  end

  defp sse(events) do
    Enum.map_join(events, "", fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end

  defp asks_for_create_issue do
    sse([
      %{"type" => "message_start", "message" => message_start()},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Let me file it."}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "create_issue",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"title": "x"})}
      },
      %{"type" => "content_block_stop", "index" => 1},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}, "usage" => usage()},
      %{"type" => "message_stop"}
    ])
  end

  defp answers do
    sse([
      %{"type" => "message_start", "message" => message_start()},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "done"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => usage()},
      %{"type" => "message_stop"}
    ])
  end

  defp message_start do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5",
      "content" => [],
      "usage" => usage()
    }
  end

  defp usage, do: %{"input_tokens" => 1, "output_tokens" => 1}

  defp provider(test_pid) do
    counter = :counters.new(1, [])

    fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      :counters.add(counter, 1, 1)

      reply = reply(:counters.get(counter, 1), body, test_pid)

      conn
      |> Conn.put_resp_content_type("text/event-stream")
      |> Conn.resp(200, reply)
    end
  end

  defp reply(1, _body, _test_pid), do: asks_for_create_issue()

  defp reply(_count, body, test_pid) do
    send(test_pid, {:second_request, Jason.decode!(body)})
    answers()
  end
end
