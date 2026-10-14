defmodule CodeMySpec.Agents.ADispatchFromInsideTheChannelIsRefusedTest do
  @moduledoc """
  A transport call to the process making it is refused rather than made.

  `Transport.Harness` resolves the copy's holder from `HarnessRegistry` and
  `GenServer.call`s it. When the caller *is* that holder the call is a deadlock,
  and the BEAM turns it into an exit — which kills the harness project channel,
  and takes every agent on that copy with it: the harness rejoins, and
  `Agents.account_for_interrupted_turns/2` tells each one its turn was
  discarded.

  Measured on the math project 2026-09-22. An in-BEAM agent completing a task
  ran `TaskEvaluator.reconsider_other_agents/2` inside the channel, which
  dispatched a work turn to the copy's holder — itself:

      [HarnessProject] channel DIED reason={:calling_self,
        {GenServer, :call, [#PID<0.14373.0>, {:request_work_turn, ...

  One agent finishing its work cancelled everybody else's, and the `rescue` at
  that call site never stood a chance: `:calling_self` is an exit, not an
  exception.

  Moving that caller into a Task is the fix. This is the floor under it, because
  it is not the only path that can get there — `set_working_copy_loop` and
  `check_in` both reach `Work.consider_*` one MCP call away from the channel.
  A refusal is something a caller can report; a dead channel is four cancelled
  turns and a rejoin.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Transport.Harness

  @registry CodeMySpec.Analysis.HarnessRegistry

  setup do
    copy_id = Ecto.UUID.generate()
    {:ok, _} = Registry.register(@registry, copy_id, {"test-instance", "/tmp/whatever"})
    %{copy_id: copy_id, agent: %Agent{id: Ecto.UUID.generate()}}
  end

  test "a work turn dispatched from the holder itself is refused, not called", ctx do
    # Registered above, so the holder for this copy is this very process.
    assert {:error, :would_deadlock} =
             Harness.request_work_turn(ctx.copy_id, ctx.agent, "ref", "go", 50)
  end

  # The other half: the guard must not swallow ordinary dispatch. A holder that
  # is somebody else is called for real — here a process that never replies, so
  # the call times out, which is the transport's own answer and proves it got
  # as far as making the call.
  test "a work turn dispatched to a different holder is still called", ctx do
    parent = self()
    other_copy = Ecto.UUID.generate()

    holder =
      spawn(fn ->
        {:ok, _} = Registry.register(@registry, other_copy, {"other", "/tmp/other"})
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 1_000

    assert {:error, :message_timed_out} =
             Harness.request_work_turn(other_copy, ctx.agent, "ref", "go", 10)

    Process.exit(holder, :kill)
  end
end
