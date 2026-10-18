defmodule CmsHarness.Agents.AToolErrorDoesNotKillTheAgentTest do
  @moduledoc """
  A tool that fails is a tool result, not the end of the agent. Issue `2999a0cb`.

  `check_answer` answered `{:error, %Anubis.MCP.Error{}}`. Alloy put the struct
  in the tool-result block as it was, the provider `Jason.encode!`d the next
  request, `Jason.Encoder` is not implemented for it, and the raise took the
  Alloy server, the turn task and the agent with it. Two continuous agents on
  metric_flow died that way within half an hour.

  Driven through a real turn: a provider asks for `check_answer`, the session
  answers with an `MCP.Error`, and the second request is where the crash was.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.ToolResults
  alias CmsHarness.Project.ChannelClient
  alias CmsHarnessTest.Machine
  alias Plug.Conn

  @moduletag :tmp_dir

  defmodule FailingTransport do
    @moduledoc false
    @behaviour CmsHarness.Mcp.Transport

    @impl true
    def connect(_name, _opts), do: {:ok, __MODULE__}

    @impl true
    def call(client, tool, args), do: call(client, tool, args, [])

    @impl true
    def call(_client, _tool, _args, _opts),
      do: answer(:persistent_term.get({__MODULE__, :answer}))

    defp answer({:raise, exception}), do: raise(exception)
    defp answer(answer), do: answer

    @impl true
    def list_tool_names(_client), do: {:ok, []}

    @impl true
    def list_tools(_client), do: {:ok, []}

    @impl true
    def disconnect(_client), do: :ok
  end

  @crashed %Anubis.MCP.Error{
    code: -32_603,
    reason: :internal_error,
    message: "Internal error",
    data: %{"message" => "Tool execution crashed"}
  }

  setup %{tmp_dir: tmp_dir} do
    Machine.ensure_supervisor()
    previous = Application.get_env(:code_my_spec, :harness_mcp_transport)
    Application.put_env(:code_my_spec, :harness_mcp_transport, FailingTransport)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :harness_mcp_transport, previous)
      :persistent_term.erase({FailingTransport, :answer})
    end)

    %{root: tmp_dir}
  end

  defp sse(events) do
    Enum.map_join(events, "", fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end

  defp asks_for_check_answer do
    sse([
      %{"type" => "message_start", "message" => message_start()},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "check_answer",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => ~s({"question_id": "34a663ee"})
        }
      },
      %{"type" => "content_block_stop", "index" => 0},
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
        "delta" => %{"type" => "text_delta", "text" => "noted"}
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

  # First request asks for the tool; the second carries its result, and is
  # handed to the test so it can read what the model was shown.
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

  defp reply(1, _body, _test_pid), do: asks_for_check_answer()

  defp reply(_count, body, test_pid) do
    send(test_pid, {:second_request, Jason.decode!(body)})
    answers()
  end

  defp start_agent(root) do
    id = "tool-error-#{System.unique_integer([:positive])}"
    test_pid = self()

    {:ok, _} =
      Machine.start_agent(id, root,
        provider: "anthropic",
        api_key: "unused",
        req_options: [plug: provider(test_pid)],
        on_event: fn _agent_id, envelope -> send(test_pid, {:event, envelope}) end
      )

    on_exit(fn -> Machine.stop_agent(id) end)
    id
  end

  defp tool_result(%{"messages" => messages}) do
    messages
    |> Enum.flat_map(fn
      %{"content" => blocks} when is_list(blocks) -> blocks
      _ -> []
    end)
    |> Enum.find(&(&1["type"] == "tool_result"))
  end

  test "a tool answering with an MCP.Error is a readable result, and the agent lives",
       %{root: root} do
    :persistent_term.put({FailingTransport, :answer}, {:error, @crashed})
    agent = start_agent(root)

    assert {:ok, :started} = Machine.send_message(agent, "ref-1", "collect the answer")

    assert_receive {:second_request, request}, 5_000
    result = tool_result(request)

    assert result["is_error"] == true
    assert result["content"] == "check_answer failed: Internal error: Tool execution crashed"

    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert Machine.running?(agent), "a failed tool call ended the agent"
  end

  @tag :capture_log
  test "a tool that raises is a readable result, and the agent lives", %{root: root} do
    :persistent_term.put({FailingTransport, :answer}, {:raise, RuntimeError.exception("boom")})
    agent = start_agent(root)

    assert {:ok, :started} = Machine.send_message(agent, "ref-1", "collect the answer")

    assert_receive {:second_request, request}, 5_000
    result = tool_result(request)

    assert result["is_error"] == true
    assert result["content"] =~ "boom"

    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert Machine.running?(agent)
  end

  # The other half of 2999a0cb: the agent died and nothing said so. A process
  # that goes for any reason but a stop says why on its way out, so the server
  # can put it in the thread and bring a continuous agent back.
  describe "an agent whose process dies" do
    defp quiet_agent(root) do
      id = "dies-#{System.unique_integer([:positive])}"
      test_pid = self()

      {:ok, %{pid: pid}} =
        Machine.start_agent(id, root,
          provider: "anthropic",
          api_key: "unused",
          on_event: fn _agent_id, envelope -> send(test_pid, {:event, envelope}) end
        )

      on_exit(fn -> Machine.stop_agent(id) end)
      {id, pid}
    end

    @tag :capture_log
    test "says it died, and why", %{root: root} do
      {_id, pid} = quiet_agent(root)
      ref = Process.monitor(pid)

      :sys.terminate(pid, :provider_exploded)

      assert_receive {:DOWN, ^ref, :process, ^pid, :provider_exploded}, 5_000
      assert_receive {:event, %{event: :agent_died, text: text}}, 5_000
      assert text =~ "provider_exploded"
    end

    test "a stop is not a death", %{root: root} do
      {id, pid} = quiet_agent(root)
      ref = Process.monitor(pid)

      :ok = Machine.stop_agent(id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      refute_received {:event, %{event: :agent_died}}
    end

    test "the death goes on the wire as its own kind" do
      assert %{"kind" => "agent_died", "text" => "boom"} =
               ChannelClient.encode_turn_event(%{
                 event: :agent_died,
                 text: "boom"
               })
    end
  end

  describe "describe/1" do
    test "an MCP.Error reads as its message and detail" do
      assert ToolResults.describe(@crashed) == "Internal error: Tool execution crashed"
    end

    test "a transport failure keeps its cause" do
      error = %Anubis.MCP.Error{
        code: -32_000,
        reason: :send_failure,
        message: "Send Failure",
        data: %{original_reason: :econnrefused}
      }

      assert ToolResults.describe(error) == "Send Failure: :econnrefused"
    end

    test "text stays text and anything else is inspected" do
      assert ToolResults.describe("no such story") == "no such story"
      assert ToolResults.describe(:not_found) == ":not_found"
      assert ToolResults.describe(RuntimeError.exception("boom")) == "boom"
    end
  end
end
