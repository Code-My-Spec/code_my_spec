defmodule CmsHarness.Agents.ASlowConsumeDoesNotTimeOutTheSenderTest do
  @moduledoc """
  A consume acknowledgement that legitimately takes several seconds still
  lands as a started turn, not a timeout (32185981).

  During fleet recovery after a disk-space outage, `message_agent` returned
  `:message_timed_out` for a turn that, per `list_agent_work`, was genuinely
  still opening. `Engine.send_message/5` waited only five seconds for its own
  `handle_call({:send, ...})` to answer, while `Impl.consume_message/2` --
  run inside that same `handle_call`, before it can reply at all -- acknowledges
  through `Channel.mailbox/2`, whose own budget is seventeen seconds. A
  consume slower than five seconds raised an uncaught exit that crashed the
  bare task meant to report the outcome, leaving the dispatcher waiting on a
  turn that had, in fact, started.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    CmsHarnessTest.Machine.ensure_supervisor()
    %{root: tmp_dir}
  end

  defp request(root, overrides) do
    Map.merge(
      %{
        "agent_id" => "agent-#{System.unique_integer([:positive])}",
        "provider" => "zai",
        "api_key" => "not-a-real-key",
        "working_copy" => root,
        # Nothing listens here, so the turn this starts fails at once and no
        # request leaves this machine.
        "base_url" => "http://127.0.0.1:1",
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "role" => "coding"
      },
      overrides
    )
  end

  test "a consume taking six seconds still starts the turn", %{root: root} do
    req =
      request(root, %{
        "on_consume" => fn _agent_id, _ref, _generation ->
          Process.sleep(6_000)
          :ok
        end
      })

    assert {:ok, %{agent_id: id}} = Agents.launch(req)
    on_exit(fn -> Agents.halt(id) end)

    assert {:ok, :started} = Agents.send_message(id, "a-ref", "do the thing")
  end
end
