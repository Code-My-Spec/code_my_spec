defmodule CodeMySpecWeb.ADeadHandlerStillAnswersTest do
  @moduledoc """
  A deferred handler that dies is still answered.

  Five of this channel's handlers reply from a task, because the work outlasts
  what the channel can be held for. Silence is the one answer they must never
  give: the harness sits out its full timeout on every turn, and latency is what
  a crash then looks like.

  Three of them bought that with a `rescue` around the reply function. It caught
  only what raised inside that function — a task killed by its supervisor, an
  exit, a throw, or a `DBConnection.OwnershipError` from a process that was
  never allowed all still answered nothing. The channel monitors what it starts
  instead, which covers every way of dying rather than one.

  Driven by killing the task, because that is the case the rescue could not have
  caught and the one this replaced it for. Through `analysis_run` because it
  waits on an analyzer nothing in this test will run, so the task is certain to
  be alive when the kill lands; the promise belongs to `reply_async/4`, which is
  one function and the same one for all five handlers.
  """

  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()

    {:ok, _reply, channel} =
      UserSocket
      |> socket("harness_test", %{scope: scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{scope.active_project_id}",
        %{
          "label" => "the harness at /workspace/app",
          "harness_id" => scope.active_working_copy_id,
          "device" => %{"id" => device_fixture(scope).id}
        }
      )

    %{scope: scope, channel: channel}
  end

  test "a handler whose task dies comes back as an error rather than silence",
       %{channel: channel} do
    before = handlers()
    ref = push(channel, "analysis_run", %{"source" => "exunit"})

    kill_the_new_handler(before)

    assert_reply ref, :error, %{"reason" => "handler_died"}, 5_000
  end

  test "the reply names where it died, so the harness log is not the only account",
       %{channel: channel} do
    before = handlers()
    ref = push(channel, "analysis_run", %{"source" => "exunit"})

    kill_the_new_handler(before)

    assert_reply ref, :error, %{"at" => at}, 5_000
    assert at =~ "analysis_run"
  end

  # A handler that succeeds must not also be reported dead.
  #
  # This is the defect the first version of the change shipped with, and it
  # reached dev: `start_child` then `Process.monitor` are two steps, and a
  # decision that is a few map lookups finishes in the gap between them.
  # `Process.monitor/1` on an already-dead process answers `:noproc` at once, so
  # the channel reported a successful handler dead and sent a second,
  # contradicting reply. 29 of them in three minutes.
  #
  # Driven through `pre-tool-use`, which is the fastest of the five and the one
  # it actually bit — a stop decision takes long enough to hide it, which is why
  # this test passed while dev did not.
  test "a fast handler that answers is not then reported dead", %{channel: channel} do
    for _ <- 1..25 do
      ref =
        push(channel, "hook_decision", %{
          "hook" => "pre-tool-use",
          "payload" => %{"tool_name" => "Read", "tool_input" => %{}},
          "port" => 4004
        })

      assert_reply ref, :ok, _decision, 5_000
      refute_reply ref, :error, _, 50
    end
  end

  defp handlers, do: MapSet.new(Task.Supervisor.children(CodeMySpec.TaskSupervisor))

  # The one this push started, whichever else the supervisor happens to hold.
  # Polled rather than assumed present: `push/3` returns before the channel has
  # processed the message, so the task may not exist yet.
  defp kill_the_new_handler(before) do
    pid = await_new_handler(before, 100)
    Process.exit(pid, :kill)
  end

  defp await_new_handler(before, 0) do
    flunk("no new task under the supervisor — #{inspect(MapSet.to_list(before))}")
  end

  defp await_new_handler(before, tries) do
    handlers()
    |> MapSet.difference(before)
    |> MapSet.to_list()
    |> new_handler_result(before, tries)
  end

  defp new_handler_result([pid | _], _before, _tries), do: pid

  defp new_handler_result([], before, tries) do
    Process.sleep(10)
    await_new_handler(before, tries - 1)
  end
end
