defmodule CmsHarness.RunLinkTest do
  @moduledoc """
  The harness end of a run's link (issue 128c1b27): every event acknowledged
  to the session that sent it, a replay dropped by that session's sequence,
  a rejoin adopted only for a run this harness expects or claimed, and
  cancel asked of every session.

  Sessions are this process or proxies of it; the run is put into the link's
  state as `{:expect, …}` records it, without starting distribution in the
  suite. A fake channel is registered where `ChannelClient` is looked up.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.RunLink

  setup do
    root = "/tmp/run-link-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    link = start_supervised!({RunLink, name: :"run_link_#{System.unique_integer([:positive])}"})
    run_id = System.unique_integer([:positive])
    %{link: link, root: root, run_id: run_id}
  end

  defp expect(ctx, owner \\ nil) do
    run = %{root: ctx.root, owner: owner, sessions: %{}, exits: %{}, shards: 1, finished: false}
    :sys.replace_state(ctx.link, &Map.put(&1, ctx.run_id, run))
  end

  # A session of its own that reports what it is sent, tagged.
  defp session(tag) do
    test = self()

    spawn_link(fn ->
      Stream.repeatedly(fn -> receive(do: (message -> send(test, {tag, message}))) end)
      |> Stream.run()
    end)
  end

  defp event(ctx, session, seq, event),
    do: send(ctx.link, {:run_event, ctx.run_id, session, seq, event})

  defp delivered do
    receive do
      {:"$gen_cast", {:analysis_event, %{"event" => event}}} -> event
    after
      300 -> :none
    end
  end

  test "each event is acknowledged to its session and delivered once", ctx do
    expect(ctx)
    run_id = ctx.run_id

    event(ctx, self(), 1, %{"event" => "test", "name" => "a"})
    event(ctx, self(), 2, %{"event" => "test", "name" => "b"})

    assert_receive {:run_ack, ^run_id, 1}
    assert_receive {:run_ack, ^run_id, 2}
    assert %{"name" => "a"} = delivered()
    assert %{"name" => "b"} = delivered()
  end

  test "a replay is acknowledged again but not delivered twice", ctx do
    expect(ctx)
    run_id = ctx.run_id
    event(ctx, self(), 1, %{"event" => "test", "name" => "a"})
    assert %{"name" => "a"} = delivered()

    # The ack was lost with a restart; the run sends it again.
    event(ctx, self(), 1, %{"event" => "test", "name" => "a"})
    event(ctx, self(), 2, %{"event" => "test", "name" => "b"})

    assert_receive {:run_ack, ^run_id, 1}
    assert_receive {:run_ack, ^run_id, 1}
    assert %{"name" => "b"} = delivered()
    assert delivered() == :none
  end

  test "shards count from 1 each and are not taken for replays of one another", ctx do
    expect(ctx)
    run_id = ctx.run_id
    {one, two} = {session(:one), session(:two)}

    event(ctx, one, 1, %{"event" => "test", "name" => "shard 1's"})
    event(ctx, two, 1, %{"event" => "test", "name" => "shard 2's"})

    assert_receive {:one, {:run_ack, ^run_id, 1}}
    assert_receive {:two, {:run_ack, ^run_id, 1}}
    assert %{"name" => "shard 1's"} = delivered()
    assert %{"name" => "shard 2's"} = delivered()
  end

  test "a rejoin is adopted for a run this harness holds and refused otherwise", ctx do
    run_id = ctx.run_id
    send(ctx.link, {:run_rejoin, run_id, :run@host, self()})
    assert_receive {:run_refused, ^run_id}

    # Not this harness's run: unacknowledged, so the run keeps looking.
    event(ctx, self(), 1, %{"event" => "test"})
    refute_receive {:run_ack, ^run_id, _}, 100
    assert delivered() == :none

    expect(ctx)
    send(ctx.link, {:run_rejoin, run_id, :run@host, self()})
    assert_receive {:run_adopted, ^run_id}
  end

  test "a claimed run's owner is told its exit status, and the run finishes once", ctx do
    expect(ctx, self())
    run_id = ctx.run_id

    event(ctx, self(), 1, %{"event" => "exit", "status" => 2})

    assert_receive {:run_ack, ^run_id, 1}
    assert_receive {:run_exited, ^run_id, 2}
    assert %{"event" => "finished"} = delivered()

    :ok = RunLink.exited(run_id, ctx.link)
    assert delivered() == :none
  end

  # Credo's own `finished` carries its totals; the exit after it must not
  # replace them with a bare one.
  test "a run that reported its own finish is not finished again by its exit", ctx do
    expect(ctx)
    event(ctx, self(), 1, %{"event" => "finished", "files" => 3, "findings" => 1})
    event(ctx, self(), 2, %{"event" => "exit", "status" => 0})

    assert %{"event" => "finished", "files" => 3} = delivered()
    assert delivered() == :none
  end

  test "cancelling asks every session of the run to stop", ctx do
    expect(ctx)
    run_id = ctx.run_id
    {one, two} = {session(:one), session(:two)}
    send(ctx.link, {:run_rejoin, run_id, :run_s1@host, one})
    send(ctx.link, {:run_rejoin, run_id, :run_s2@host, two})

    :ok = RunLink.cancel(run_id, ctx.link)

    assert_receive {:one, {:run_cancel, ^run_id}}
    assert_receive {:two, {:run_cancel, ^run_id}}
  end

  # The exit's ack lost to a disconnect: the run rejoins and replays it. A
  # finished run stays to acknowledge that, or the run waits forever.
  test "a finished run adopts a rejoin and acknowledges its replay, delivering nothing", ctx do
    expect(ctx, self())
    run_id = ctx.run_id
    event(ctx, self(), 1, %{"event" => "test", "name" => "a"})
    event(ctx, self(), 2, %{"event" => "exit", "status" => 0})
    assert_receive {:run_exited, ^run_id, 0}
    assert %{"name" => "a"} = delivered()
    assert %{"event" => "finished"} = delivered()
    flush_acks(run_id)

    send(ctx.link, {:run_rejoin, run_id, :run@host, self()})
    assert_receive {:run_adopted, ^run_id}
    event(ctx, self(), 1, %{"event" => "test", "name" => "a"})
    event(ctx, self(), 2, %{"event" => "exit", "status" => 0})

    assert_receive {:run_ack, ^run_id, 1}
    assert_receive {:run_ack, ^run_id, 2}
    assert delivered() == :none
    refute_received {:run_exited, ^run_id, _}

    # Its command exiting later does not finish it a second time.
    :ok = RunLink.exited(run_id, ctx.link)
    assert delivered() == :none
  end

  test "a finished run is forgotten after its tombstone, and then is not this harness's", ctx do
    expect(ctx)
    run_id = ctx.run_id
    event(ctx, self(), 1, %{"event" => "exit", "status" => 0})
    assert_receive {:run_ack, ^run_id, 1}

    # What the tombstone timer sends.
    send(ctx.link, {:forget, run_id})
    send(ctx.link, {:run_rejoin, run_id, :run@host, self()})

    assert_receive {:run_refused, ^run_id}
  end

  test "a run is cancelled at its node by its own session, adopted or not" do
    Process.register(self(), ClientUtils.RunLink.Session)

    :ok = RunLink.cancel_at(Atom.to_string(node()), 42)

    assert_receive {:run_cancel, 42}
  end

  test "a copy no longer served has every recorded run stopped and forgotten", ctx do
    Process.register(self(), ClientUtils.RunLink.Session)
    id = 2_000_000_000 + System.unique_integer([:positive])
    other = id + 1

    on_exit(fn ->
      CodeMySpec.DurableRun.cleanup(id)
      CodeMySpec.DurableRun.cleanup(other)
    end)

    CodeMySpec.DurableRun.begin_run(id, ctx.root, "exunit", [], "abc")
    CodeMySpec.DurableRun.update(id, %{"node" => Atom.to_string(node())})
    CodeMySpec.DurableRun.begin_run(other, "/still-served-#{id}", "exunit", [], "abc")

    :ok = RunLink.cancel_copy(ctx.root, ctx.link)

    assert_receive {:run_cancel, ^id}
    assert {:error, :enoent} = CodeMySpec.DurableRun.read_manifest(id)
    assert {:ok, _} = CodeMySpec.DurableRun.read_manifest(other)
    refute_receive {:run_cancel, ^other}, 100
  end

  # The backstop fires five seconds after a cancel, when a run that heeded it
  # is already gone; failing loudly then logged an error into whatever ran next.
  test "the halt backstop for a run already gone logs nothing", ctx do
    expect(ctx)
    run_id = ctx.run_id
    send(ctx.link, {:run_rejoin, run_id, :"gone_#{run_id}@127.0.0.1", self()})
    assert_receive {:run_adopted, ^run_id}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(ctx.link, {:halt, run_id})
        _ = :sys.get_state(ctx.link)
        Process.sleep(200)
      end)

    refute log =~ "noconnection"
  end

  describe "halt_nodes/2" do
    # Every node epmd lists on the run's host, as `names` answers; each halt
    # comes here.
    defp halted(base, listed) do
      test = self()

      :ok =
        RunLink.halt_nodes(base,
          names: fn "127.0.0.1" -> listed end,
          cast: fn node, :erlang, :halt, [137] -> send(test, {:halted, node}) end
        )

      receive_halted([])
    end

    defp receive_halted(acc) do
      receive do
        {:halted, node} -> receive_halted([node | acc])
      after
        0 -> Enum.sort(acc)
      end
    end

    test "halts the run's runner and every shard of it, linked or not" do
      assert halted("cms_run_7_100_5@127.0.0.1", [
               "cms_run_7_100_5",
               "cms_run_7_100_5_s1",
               "cms_run_7_100_5_s12",
               "cms_harness_100"
             ]) ==
               Enum.sort([
                 :"cms_run_7_100_5@127.0.0.1",
                 :"cms_run_7_100_5_s1@127.0.0.1",
                 :"cms_run_7_100_5_s12@127.0.0.1"
               ])
    end

    test "never a node whose name only begins with the run's" do
      assert halted("cms_run_7_100_5@127.0.0.1", [
               "cms_run_7_100_50",
               "cms_run_7_100_5_s1x",
               "cms_run_7_100_5_sx",
               "cms_run_7_100_5_s",
               "xcms_run_7_100_5"
             ]) == []
    end

    test "a run with no node recorded halts nothing" do
      assert :ok = RunLink.halt_nodes(nil, names: fn _ -> flunk("asked epmd") end)
    end
  end

  defp flush_acks(run_id) do
    receive do
      {:run_ack, ^run_id, _} -> flush_acks(run_id)
    after
      0 -> :ok
    end
  end
end
