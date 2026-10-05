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

  describe "an agent's Keeper" do
    # `watch` and `watch_keeper` are casts; a call after them is answered only
    # once both are handled, so a kill after this is one Liveness was watching.
    defp watched(root), do: Liveness.present(root)

    test "gone after a crash is a giving-up, said once", %{root: root} do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch("a1", pid, root)
      :ok = Liveness.watch_keeper("a1", keeper, root)
      watched(root)

      Process.exit(pid, :boom)
      assert_receive {:agent_liveness, :down, "a1", ^root, :boom}
      Process.exit(keeper, :kill)

      assert_receive {:agent_liveness, :gave_up, "a1", ^root, :boom}
      refute_receive {:agent_liveness, :gave_up, "a1", _, _}, 100
    end

    test "is a giving-up whichever of the two downs arrives first", %{root: root} do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch("a1", pid, root)
      :ok = Liveness.watch_keeper("a1", keeper, root)
      watched(root)

      Process.exit(keeper, :kill)
      refute_receive {:agent_liveness, :gave_up, "a1", _, _}, 100
      Process.exit(pid, :boom)

      assert_receive {:agent_liveness, :gave_up, "a1", ^root, :boom}
    end

    test "gone after a stop says nothing more than the stop's down", %{root: root} do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch("a1", pid, root)
      :ok = Liveness.watch_keeper("a1", keeper, root)
      watched(root)

      Process.exit(pid, :shutdown)
      assert_receive {:agent_liveness, :down, "a1", ^root, :shutdown}
      Process.exit(keeper, :kill)

      refute_receive {:agent_liveness, :gave_up, "a1", _, _}, 100
    end

    test "a restart is a down and an up, and no giving-up", %{root: root} do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch("a1", pid, root)
      :ok = Liveness.watch_keeper("a1", keeper, root)
      watched(root)

      Process.exit(pid, :boom)
      :ok = Liveness.watch("a1", an_agent(), root)

      assert_receive {:agent_liveness, :down, "a1", ^root, :boom}
      assert_receive {:agent_liveness, :up, "a1", ^root, nil}
      refute_receive {:agent_liveness, :gave_up, "a1", _, _}, 100
      assert Liveness.present(root) == ["a1"]
    end
  end
end
