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

  defp reply_body do
    Jason.encode!(%{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5",
      "content" => [%{"type" => "text", "text" => "ok"}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    })
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
      |> Plug.Conn.put_resp_content_type("application/json")
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
