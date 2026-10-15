defmodule CodeMySpec.Promotion.AnUnreachableGateHarnessIsMarkedTest do
  @moduledoc """
  2026-10-15: v2.0.515 landed, the harness restarted, and the next batch was
  built in that second. The gate copy's machine was not registered, and a sound
  candidate (d759ce130) was ejected for it. The runner marks an unreachable
  harness so the queue waits it out instead (`Worker.wait_for_gate_harness/3`).
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Runner

  test "a batch build on a copy whose harness is not registered says it was unreachable" do
    copy_id = Ecto.UUID.generate()
    env = Environment.new(:harness, "/nowhere")

    assert {:error, %{unreachable: true, reason: reason}} =
             Runner.build_batch(env, "/nowhere", "main", ["abc"], copy_id)

    assert reason =~ "harness_not_registered"
  end
end
