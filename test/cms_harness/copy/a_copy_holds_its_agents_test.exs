defmodule CmsHarness.Copy.ACopyHoldsItsAgentsTest do
  @moduledoc """
  Phase 2b: everything the harness runs for a working copy lives under that
  copy's `Copy.Supervisor` — the tree mirrors copy → agents. Offboarding the
  copy stops its agents with it, and only its own.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Keeper
  alias CmsHarness.Agents.Liveness
  alias CmsHarness.Copy.Supervisor, as: Copy
  alias CmsHarnessTest.Machine

  setup do
    {:ok, root} = Briefly.create(directory: true)
    root = Path.expand(root)
    id = Ecto.UUID.generate()
    :ok = Liveness.subscribe()

    {:ok, %{pid: pid}} = Machine.start_agent(id, root)
    on_exit(fn -> Copy.stop(root) end)
    assert_receive {:agent_liveness, :up, ^id, ^root, nil}

    %{root: root, id: id, pid: pid}
  end

  test "an agent runs under its copy", ctx do
    assert {:ok, copy} = Copy.whereis(ctx.root)

    assert [{_, keeper, :supervisor, _}] =
             ctx.root |> Copy.agents() |> DynamicSupervisor.which_children()

    assert {:ok, ^keeper, _root} = Keeper.whereis(ctx.id)
    assert Process.alive?(copy)
  end

  test "stopping the copy stops its agents", ctx do
    assert :ok = Copy.stop(ctx.root)

    id = ctx.id
    root = ctx.root
    assert_receive {:agent_liveness, :down, ^id, ^root, :shutdown}
    refute Machine.running?(ctx.id)
  end

  test "stopping one copy leaves another copy's agents alone", ctx do
    {:ok, other} = Briefly.create(directory: true)
    other = Path.expand(other)
    other_id = Ecto.UUID.generate()
    {:ok, _} = Machine.start_agent(other_id, other)
    on_exit(fn -> Copy.stop(other) end)
    assert_receive {:agent_liveness, :up, ^other_id, ^other, nil}

    assert :ok = Copy.stop(ctx.root)

    refute_receive {:agent_liveness, :down, ^other_id, _, _}, 200
    assert Machine.running?(other_id)
  end
end
