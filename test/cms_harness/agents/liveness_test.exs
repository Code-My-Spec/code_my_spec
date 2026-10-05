defmodule CmsHarness.Agents.LivenessTest do
  @moduledoc """
  `Liveness` reports an agent's process up when the engine starts it and down
  the moment it dies, by working copy — the harness half of agent presence.
  """

  # The harness tree's own `Liveness`, shared by everything on it: each test
  # watches its own copy, so it hears its own agents only.
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Liveness

  setup do
    assert GenServer.whereis(Liveness), "the harness tree runs Liveness in the test env"
    :ok = Liveness.subscribe()
    %{root: "/tmp/liveness-copy-#{System.unique_integer([:positive])}"}
  end

  defp an_agent do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  test "a watched agent is up in its copy", %{root: root} do
    :ok = Liveness.watch("a1", an_agent(), root)

    assert_receive {:agent_liveness, :up, "a1", ^root, nil}
    assert Liveness.present(root) == ["a1"]
    assert Liveness.present(root <> "-another") == []
  end

  test "its death is reported at once, with the reason", %{root: root} do
    pid = an_agent()
    :ok = Liveness.watch("a1", pid, root)
    assert_receive {:agent_liveness, :up, "a1", ^root, _}

    Process.exit(pid, :kill)

    assert_receive {:agent_liveness, :down, "a1", ^root, :killed}
    assert Liveness.present(root) == []
  end

  test "watching the same process twice reports it up once", %{root: root} do
    pid = an_agent()
    :ok = Liveness.watch("a1", pid, root)
    :ok = Liveness.watch("a1", pid, root)

    assert_receive {:agent_liveness, :up, "a1", ^root, _}
    refute_receive {:agent_liveness, :up, "a1", ^root, _}, 100
    assert Liveness.present(root) == ["a1"]
  end

  test "a root is compared expanded", %{root: root} do
    :ok = Liveness.watch("a1", an_agent(), root <> "/./")
    assert_receive {:agent_liveness, :up, "a1", ^root, _}
    assert Liveness.present(root) == ["a1"]
  end
end
