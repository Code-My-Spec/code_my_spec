defmodule CmsHarness.Agents.LivenessTest do
  @moduledoc """
  `Liveness` reports an agent's process up when the engine starts it and down
  the moment it dies, by working copy — the harness half of agent presence.
  """

  # Liveness is one application-wide server. Unique roots isolate its
  # records, but every subscriber receives every event through the same
  # mailbox. Keep delivery timing assertions apart from concurrent tests
  # that also create and stop agents on that server.
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Liveness

  setup do
    assert GenServer.whereis(Liveness), "the harness tree runs Liveness in the test env"
    :ok = Liveness.subscribe()
    # Its own id per test: Liveness remembers a giving-up by agent id, and
    # tests sharing one hear each other's.
    n = System.unique_integer([:positive])
    %{root: "/tmp/liveness-copy-#{n}", id: "a#{n}"}
  end

  defp an_agent do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  test "a watched agent is up in its copy", %{root: root, id: id} do
    :ok = Liveness.watch(id, an_agent(), root)

    assert_receive {:agent_liveness, :up, ^id, ^root, nil}
    assert Liveness.present(root) == [id]
    assert Liveness.present(root <> "-another") == []
  end

  test "its death is reported at once, with the reason", %{root: root, id: id} do
    pid = an_agent()
    :ok = Liveness.watch(id, pid, root)
    assert_receive {:agent_liveness, :up, ^id, ^root, _}

    Process.exit(pid, :kill)

    assert_receive {:agent_liveness, :down, ^id, ^root, :killed}
    assert Liveness.present(root) == []
  end

  test "watching the same process twice reports it up once", %{root: root, id: id} do
    pid = an_agent()
    :ok = Liveness.watch(id, pid, root)
    :ok = Liveness.watch(id, pid, root)

    assert_receive {:agent_liveness, :up, ^id, ^root, _}
    refute_receive {:agent_liveness, :up, ^id, ^root, _}, 100
    assert Liveness.present(root) == [id]
  end

  test "a root is compared expanded", %{root: root, id: id} do
    :ok = Liveness.watch(id, an_agent(), root <> "/./")
    assert_receive {:agent_liveness, :up, ^id, ^root, _}
    assert Liveness.present(root) == [id]
  end

  describe "an agent's Keeper" do
    # `watch` and `watch_keeper` are casts; a call after them is answered only
    # once both are handled, so a kill after this is one Liveness was watching.
    defp watched(root), do: Liveness.present(root)

    test "gone after a crash is a giving-up, said once", %{root: root, id: id} do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch(id, pid, root)
      :ok = Liveness.watch_keeper(id, keeper, root)
      watched(root)

      Process.exit(pid, :boom)
      assert_receive {:agent_liveness, :down, ^id, ^root, :boom}
      Process.exit(keeper, :kill)

      assert_receive {:agent_liveness, :gave_up, ^id, ^root, :boom}
      refute_receive {:agent_liveness, :gave_up, ^id, _, _}, 100
    end

    test "is a giving-up whichever of the two downs arrives first", %{root: root, id: id} do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch(id, pid, root)
      :ok = Liveness.watch_keeper(id, keeper, root)
      watched(root)

      Process.exit(keeper, :kill)
      refute_receive {:agent_liveness, :gave_up, ^id, _, _}, 100
      Process.exit(pid, :boom)

      assert_receive {:agent_liveness, :gave_up, ^id, ^root, :boom}
    end

    test "gone after a stop says nothing more than the stop's down", %{root: root, id: id} do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch(id, pid, root)
      :ok = Liveness.watch_keeper(id, keeper, root)
      watched(root)

      Process.exit(pid, :shutdown)
      assert_receive {:agent_liveness, :down, ^id, ^root, :shutdown}
      Process.exit(keeper, :kill)

      refute_receive {:agent_liveness, :gave_up, ^id, _, _}, 100
    end

    test "a restart is a down and an up, and no giving-up", %{root: root, id: id} do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch(id, pid, root)
      :ok = Liveness.watch_keeper(id, keeper, root)
      watched(root)

      Process.exit(pid, :boom)
      :ok = Liveness.watch(id, an_agent(), root)

      assert_receive {:agent_liveness, :down, ^id, ^root, :boom}
      assert_receive {:agent_liveness, :up, ^id, ^root, nil}
      refute_receive {:agent_liveness, :gave_up, ^id, _, _}, 100
      assert Liveness.present(root) == [id]
    end
  end

  describe "an agent its Keeper gave up on" do
    test "is remembered for the copy's join to report, until it comes up again", %{
      root: root,
      id: id
    } do
      {pid, keeper} = {an_agent(), an_agent()}
      :ok = Liveness.watch(id, pid, root)
      :ok = Liveness.watch_keeper(id, keeper, root)
      Liveness.present(root)

      Process.exit(pid, :boom)
      Process.exit(keeper, :kill)
      assert_receive {:agent_liveness, :gave_up, ^id, ^root, :boom}

      assert [%{"agent_id" => ^id, "reason" => ":boom", "at" => at}] = Liveness.gave_up(root)
      assert {:ok, _at, 0} = DateTime.from_iso8601(at)
      assert Liveness.gave_up(root <> "-another") == []

      :ok = Liveness.watch(id, an_agent(), root)
      assert_receive {:agent_liveness, :up, ^id, ^root, nil}
      assert Liveness.gave_up(root) == []
    end
  end
end
