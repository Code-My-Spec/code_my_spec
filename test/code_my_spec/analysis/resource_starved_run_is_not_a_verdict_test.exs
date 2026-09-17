defmodule CodeMySpec.Analysis.ResourceStarvedRunIsNotAVerdictTest do
  @moduledoc """
  `5d798e1a` — a run whose every finding is an identical exit against one
  shared pid caught a starving process, not a regression, and must not
  persist per-file blocking problems.

  Deliberately narrow: only the exact "GenServer.call against one shared
  pid" shape counts. A mix of that with a real assertion failure, or a
  different exit shape entirely, must not be swept up with it.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Execution

  @starved_a %{
    message:
      "** (exit) exited in: GenServer.call(#PID<0.8371.0>, {:monitor, #PID<0.16836.0>}, 5000)"
  }
  @starved_b %{
    message:
      "** (exit) exited in: GenServer.call(#PID<0.8371.0>, {:monitor, #PID<0.16797.0>}, 5000)"
  }
  @different_pid %{
    message:
      "** (exit) exited in: GenServer.call(#PID<0.9999.0>, {:monitor, #PID<0.111.0>}, 5000)"
  }
  @real_failure %{message: "Assertion with == failed\ncode:  assert 1 == 2"}

  test "every finding an identical exit against one pid is starved" do
    assert Execution.starved?([@starved_a, @starved_b])
  end

  test "a single finding matching the shape is still starved" do
    assert Execution.starved?([@starved_a])
  end

  test "no findings is not starved" do
    refute Execution.starved?([])
  end

  test "an unrelated real assertion failure is not starved" do
    refute Execution.starved?([@real_failure])
  end

  test "one real failure mixed into otherwise-identical exits is not starved" do
    refute Execution.starved?([@starved_a, @starved_b, @real_failure])
  end

  test "exits against two different pids are not starved" do
    refute Execution.starved?([@starved_a, @different_pid])
  end

  test "an exit shape this pattern does not recognize is not starved" do
    refute Execution.starved?([%{message: "** (EXIT from #PID<0.1.0>) an exception was raised"}])
  end
end
