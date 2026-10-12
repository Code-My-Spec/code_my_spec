defmodule CmsHarness.Agents.ACrashedAgentIsRestartedAsItselfTest do
  @moduledoc """
  An agent's process that crashes is restarted by its `Engine.Keeper`, from what
  it last wrote down — the same agent, not a fresh one with the history it was
  first started with — and a crash loop is given up on after three restarts in
  ten minutes, said once (`:gave_up`).

  The transcript is written through `Keeper.remember/2`, the call a turn makes
  at its start and settle: what is under test is what a restart does with it,
  and running a turn would need a provider.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Keeper
  alias CmsHarness.Agents.Engine.State
  alias CmsHarness.Agents.Liveness
  alias CmsHarnessTest.Machine

  setup do
    root = CodeMySpec.TempFile.owned_dir("test")
    root = Path.expand(root)
    id = Ecto.UUID.generate()
    test = self()
    :ok = Liveness.subscribe()

    {:ok, %{pid: pid}} =
      Machine.start_agent(id, root,
        on_event: fn agent_id, event -> send(test, {:event, agent_id, event}) end
      )

    on_exit(fn -> Machine.stop_agent(id) end)
    assert_receive {:agent_liveness, :up, ^id, ^root, nil}, 2_000

    %{id: id, root: root, pid: pid}
  end

  # `:kill`, because the engine traps exits: any other signal is a message it
  # handles, not a crash.
  defp crash(id, root, pid) do
    Process.exit(pid, :kill)
    assert_receive {:agent_liveness, :down, ^id, ^root, :killed}, 2_000
  end

  # The engine is registered before its `init` runs, and `init` is what asks
  # Liveness to watch it. Killing it before that watch lands is reported as
  # `:noproc`, not `:killed`. So wait for `init` (a system call is answered only
  # after it) and then for Liveness to have taken the watch it cast.
  defp restarted(id, root) do
    assert_receive {:agent_liveness, :up, ^id, ^root, nil}, 2_000
    {:ok, pid} = State.whereis(id)
    _ = :sys.get_state(pid)
    _ = Liveness.present(root)
    pid
  end

  defp texts(id) do
    {:ok, messages} = Machine.history(id)
    Enum.map(messages, &inspect/1)
  end

  test "a crash restarts it with what it last wrote down", ctx do
    :ok =
      Keeper.remember(ctx.id, %{
        messages: [Alloy.Message.user("the earlier turn")],
        in_flight: nil
      })

    crash(ctx.id, ctx.root, ctx.pid)
    restarted(ctx.id, ctx.root)

    assert [only] = texts(ctx.id)
    assert only =~ "the earlier turn"
  end

  test "a replaced engine reports readiness without fabricating completion", ctx do
    :ok = Keeper.remember(ctx.id, %{messages: [], in_flight: "fix the build"})

    crash(ctx.id, ctx.root, ctx.pid)
    restarted(ctx.id, ctx.root)

    id = ctx.id

    assert_receive {:event, ^id, %{event: :mailbox_ready, generation: generation, ref: nil}},
                   2_000

    assert is_binary(generation)
    refute_receive {:event, ^id, %{event: :turn_ended}}

    assert [asked, told] = texts(ctx.id)
    assert asked =~ "fix the build"
    assert told =~ "interrupted"

    assert Keeper.recall(ctx.id).in_flight == nil,
           "a second crash before the next turn would tell it the same interruption twice"
  end

  test "a stop is not restarted, and is not a giving-up", ctx do
    :ok = Machine.stop_agent(ctx.id)

    id = ctx.id
    root = ctx.root
    assert_receive {:agent_liveness, :down, ^id, ^root, :shutdown}, 2_000
    refute_receive {:agent_liveness, :up, ^id, _, _}, 200
    refute_receive {:agent_liveness, :gave_up, ^id, _, _}
    refute Machine.running?(ctx.id)
  end

  test "the fourth crash in ten minutes is given up on, once", ctx do
    pid =
      Enum.reduce(1..3, ctx.pid, fn _lap, pid ->
        crash(ctx.id, ctx.root, pid)
        restarted(ctx.id, ctx.root)
      end)

    crash(ctx.id, ctx.root, pid)

    id = ctx.id
    root = ctx.root
    assert_receive {:agent_liveness, :gave_up, ^id, ^root, :killed}, 2_000
    refute_receive {:agent_liveness, :up, ^id, _, _}, 200
    refute Machine.running?(ctx.id)
    assert {:error, :not_running} = Keeper.whereis(ctx.id)
  end
end
