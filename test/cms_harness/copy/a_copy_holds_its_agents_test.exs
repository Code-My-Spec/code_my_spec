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

    # `Copy.stop/1` already blocks until the whole tree -- agent included --
    # has torn down, so the agent's own `:DOWN` is enqueued in Liveness's
    # mailbox by the time this line runs. The only thing still async is
    # Liveness relaying it to subscribers off its own backlog, which a fixed
    # wall-clock wait guesses at (previously 5s, still too tight under gate
    # load: ejected ff9a042a6, then c9fec3b0). A synchronous round-trip is
    # queued behind that already-enqueued `:DOWN` -- GenServer mailboxes are
    # FIFO -- so it cannot return until Liveness has processed (and relayed)
    # it, bounding the wait by Liveness's own backlog instead of a constant.
    Liveness.present(root)

    assert_received {:agent_liveness, :down, ^id, ^root, :shutdown}
    refute Machine.running?(ctx.id)
  end

  test "scenario teardown is idempotent and leaves another copy running", ctx do
    {:ok, other} = Briefly.create(directory: true)
    other_id = Ecto.UUID.generate()
    {:ok, %{pid: other_pid}} = Machine.start_agent(other_id, other)
    on_exit(fn -> Copy.stop(other) end)

    assert :ok = Machine.stop_copy(ctx.root)
    assert :ok = Machine.stop_copy(ctx.root)
    assert {:error, :not_running} = Copy.whereis(ctx.root)
    refute Machine.running?(ctx.id)
    assert Process.alive?(other_pid)
    assert Machine.running?(other_id)
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
