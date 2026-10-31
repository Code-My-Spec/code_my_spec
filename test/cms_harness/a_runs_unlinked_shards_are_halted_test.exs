defmodule CmsHarness.ARunsUnlinkedShardsAreHaltedTest do
  @moduledoc """
  A spex run's shard hung before anything linked (issue 73258620: no session
  to ask, and a session of its own outside the runner's process group) is
  still stopped, by name: a cancel, a timeout, and a recovered run's ceiling
  each halt the runner `<base>` and its shards `<base>_s<n>`, and never a node
  whose name only begins with the run's.

  Real peer nodes stand in for the runner and a shard that never linked; this
  node becomes distributed as the harness's does. A fake channel is
  registered where `ChannelClient` is looked up by root.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Sync
  alias CodeMySpec.Analysis.RunNode
  alias CodeMySpec.DurableRun

  setup do
    :ok = RunNode.ensure_started("cms_harness")
    base = "cms_run_t#{System.unique_integer([:positive])}_1_1"
    # The runner, a shard that never linked, and a stranger whose name only
    # begins with the run's.
    nodes = Enum.map([base, "#{base}_s1", "#{base}0"], &start_peer/1)
    on_exit(fn -> Enum.each(nodes, &:rpc.cast(&1, :erlang, :halt, [])) end)
    Enum.each(nodes, &Node.monitor(&1, true))

    root = Path.join(System.tmp_dir!(), "unlinked-#{System.unique_integer([:positive])}")
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    id = 2_000_000_000 + System.unique_integer([:positive])
    on_exit(fn -> DurableRun.cleanup(id) end)

    [runner, shard, stranger] = nodes
    %{root: root, id: id, runner: runner, shard: shard, stranger: stranger}
  end

  defp start_peer(name) do
    {:ok, _pid, node} =
      :peer.start(%{name: String.to_atom(name), host: ~c"127.0.0.1", longnames: true})

    node
  end

  defp record(ctx, fields \\ %{}) do
    DurableRun.begin_run(ctx.id, ctx.root, "spex", [], "abc")
    :ok = DurableRun.update(ctx.id, Map.merge(%{"node" => Atom.to_string(ctx.runner)}, fields))
  end

  defp start_queue(ctx) do
    start_supervised!({Task.Supervisor, name: Sync.task_supervisor(ctx.root)})
    start_supervised!({AnalysisServer, project: %{root: ctx.root}})
  end

  defp assert_halted(ctx) do
    {runner, shard} = {ctx.runner, ctx.shard}
    assert_receive {:nodedown, ^runner}, 15_000
    assert_receive {:nodedown, ^shard}, 15_000
    assert Node.ping(ctx.stranger) == :pong, "a node only named like the run's was halted"
  end

  test "cancelling a recovered run halts its runner and its unlinked shard", ctx do
    record(ctx)
    start_queue(ctx)

    assert :ok = AnalysisServer.cancel_run(ctx.root, ctx.id)

    assert_receive {:"$gen_cast", {:analysis_result, %{"status" => "cancelled"}}}
    assert_halted(ctx)
  end

  test "a recovered run that never reports is halted at the ceiling and answered", ctx do
    started = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.to_iso8601()
    record(ctx, %{"started_at" => started})
    start_queue(ctx)

    assert_receive {:"$gen_cast", {:analysis_result, payload}}, 5_000
    assert payload["status"] == "error"
    assert payload["error"] =~ "timed out"
    assert_halted(ctx)
  end

  test "a run that times out has its shards halted, not left behind its runner", ctx do
    record(ctx)
    start_supervised!({Task.Supervisor, name: Sync.task_supervisor(ctx.root)})

    task =
      Task.Supervisor.async_nolink(Sync.task_supervisor(ctx.root), fn ->
        Process.sleep(:infinity)
      end)

    state = %{
      project: %{root: ctx.root},
      running: %{run_id: ctx.id, source: "spex", task: task, args: [], tied_run_ids: []},
      queue: [],
      pending_cleanups: [],
      recovering: %{},
      timer: nil
    }

    {:noreply, _state} = AnalysisServer.handle_info({:timeout, ctx.id}, state)

    assert_halted(ctx)
  end
end
