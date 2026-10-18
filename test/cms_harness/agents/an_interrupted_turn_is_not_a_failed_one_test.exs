defmodule CmsHarness.Agents.AnInterruptedTurnIsNotAFailedOneTest do
  @moduledoc """
  Stopping a turn so a message sent now can reach the agent ends the turn; it
  does not fail it.

  It was reported as `turn_failed ":interrupted"`, so the server told main
  "Your last turn failed", offered the turn again, and flagged main stalled,
  while the message it was stopped for was already next (2026-10-13).
  """
  use ExUnit.Case, async: false

  alias CmsHarnessTest.Machine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Machine.ensure_supervisor()
    %{root: tmp_dir}
  end

  # A streamed reply: the engine runs its turns through `Alloy.stream/3`, and
  # Alloy's Anthropic stream reads server-sent events.
  defp reply_body do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5",
          "content" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "ok"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 1}
      },
      %{"type" => "message_stop"}
    ]
    |> Enum.map_join("", &"event: #{&1["type"]}\ndata: #{Jason.encode!(&1)}\n\n")
  end

  defp holding_plug(test_pid) do
    fn conn ->
      send(test_pid, {:holding_turn, self()})

      receive do
        :release -> :ok
      after
        10_000 -> :ok
      end

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, reply_body())
    end
  end

  test "an interrupted turn ends without reporting a failure", %{root: root} do
    id = "interrupted-#{System.unique_integer([:positive])}"
    test_pid = self()

    {:ok, _} =
      Machine.start_agent(id, root,
        provider: "anthropic",
        api_key: "unused",
        req_options: [plug: holding_plug(test_pid)],
        on_event: fn _agent_id, envelope -> send(test_pid, {:event, envelope}) end
      )

    on_exit(fn -> Machine.stop_agent(id) end)

    assert {:ok, :started} = Machine.send_message(id, "ref-a", "work on this")
    assert_receive {:holding_turn, _plug}, 5_000

    CmsHarness.Agents.interrupt(id)

    assert_receive {:event, %{event: :turn_ended}}, 5_000

    refute_received {:event, %{event: :turn_failed}},
                    "an interrupt was reported as a failed turn, so the server offered it again"
  end
end
