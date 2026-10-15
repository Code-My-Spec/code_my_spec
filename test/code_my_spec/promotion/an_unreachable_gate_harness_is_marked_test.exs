defmodule CodeMySpec.Promotion.AnUnreachableGateHarnessIsMarkedTest do
  @moduledoc """
  2026-10-15: v2.0.515 landed, the harness restarted, and the next batch was
  built in that second. The gate copy's machine was not registered, and a sound
  candidate (d759ce130) was ejected for it; at 14:59 another (75e9ae96f) went
  the same way when a landing's code reload took the harness channel down. The
  runner marks an unreachable harness so the queue waits it out instead
  (`Worker.wait_for_gate_harness/3`).
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Runner

  test "a batch build on a copy whose harness is not registered says it was unreachable" do
    copy_id = Ecto.UUID.generate()
    env = Environment.new(:harness, "/nowhere")

    assert {:error, %{unreachable: true, reason: reason}} =
             Runner.build_batch(env, "/nowhere", "main", ["abc"], copy_id)

    assert reason =~ "harness_not_registered"
  end

  test "a harness that goes down mid-build is marked unreachable too" do
    copy_id = Ecto.UUID.generate()
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(copy_id, "dying", "/nowhere")
      send(test, :registered)

      receive do
        {:"$gen_call", _from, _request} -> exit(:reloading)
      end
    end)

    assert_receive :registered, 2_000

    assert {:error, %{unreachable: true, reason: reason}} =
             Runner.build_batch(
               Environment.new(:harness, "/nowhere"),
               "/nowhere",
               "main",
               ["abc"],
               copy_id
             )

    assert reason =~ "harness_gone"
  end
end
