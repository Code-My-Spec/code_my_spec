defmodule CmsHarness.ARecoveredRunIsAnsweredOnceTest do
  @moduledoc """
  Each path a harness takes with a durable run it finds on boot, or is still
  watching (issue 128c1b27): adopted while its process lives, answered from its
  stream when it ends, answered as an error when its stream is incomplete, and
  forgotten only once the server has every answer.

  Driven through the queue's own callbacks on manifests written to disk; a
  fake channel is registered where `ChannelClient` is looked up by root.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer
  alias CodeMySpec.DurableRun

  setup do
    root = "/recovered-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    id = 2_000_000_000 + System.unique_integer([:positive])
    on_exit(fn -> DurableRun.cleanup(id) end)
    %{root: root, id: id}
  end

  defp begin(ctx, tied \\ []),
    do: DurableRun.begin_run(ctx.id, ctx.root, "exunit", [], "abc", tied)

  defp boot(ctx) do
    {:ok, state} = AnalysisServer.init(%{root: ctx.root})
    state
  end

  defp poll(state) do
    {:noreply, state} = AnalysisServer.handle_info(:poll_recovery, state)
    state
  end

  # Attached to a process that has since ended: no process has this identity.
  defp gone(ctx),
    do:
      DurableRun.update(ctx.id, %{"pid" => 999_999, "identity" => "ended", "status" => "running"})

  # A process this test owns, attached as the run's.
  defp live_process(ctx) do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    :ok = DurableRun.attach_pid(ctx.id, pid)
    pid
  end

  defp append(ctx, events) do
    File.write!(
      DurableRun.stream_path(ctx.id),
      Enum.map_join(events, &(Jason.encode!(&1) <> "\n")),
      [:append]
    )
  end

  defp finished(counts),
    do:
      Map.merge(
        %{event: "suite_finished", pass: 0, fail: 0, skip: 0, excluded: 0, invalid: 0},
        counts
      )

  defp failed(name),
    do: %{event: "test_failed", name: name, file: "test/a_test.exs", line: 4, message: "boom"}

  test "a run left by the previous harness is held and claimed on join", ctx do
    begin(ctx, [ctx.id + 1])
    state = boot(ctx)

    assert Map.has_key?(state.recovering, ctx.id)
    assert {:reply, ids, _} = AnalysisServer.handle_call(:in_flight, self(), state)
    assert Enum.sort(ids) == [ctx.id, ctx.id + 1]

    # The server re-sends what it joined; held, it is not queued a second time.
    {:noreply, state} =
      AnalysisServer.handle_cast(
        {:enqueue, [%{"run_id" => ctx.id + 1, "source" => "exunit", "args" => []}]},
        state
      )

    assert state.queue == []
  end

  test "a run still alive is adopted: its events are relayed and nothing is answered", ctx do
    begin(ctx)
    live_process(ctx)
    append(ctx, [%{event: "test_passed", name: "passes", file: "test/a_test.exs", line: 3}])

    state = ctx |> boot() |> poll()

    assert_receive {:"$gen_cast", {:analysis_event, %{"run_id" => id, "event" => event}}}
    assert id == ctx.id
    assert %{"event" => "test", "state" => "passed", "name" => "passes"} = event
    refute_receive {:"$gen_cast", {:analysis_result, _}}, 100
    assert state.recovering[ctx.id]["status"] == "running"

    # The cursor is kept: the next poll relays nothing it already relayed.
    poll(state)
    refute_receive {:"$gen_cast", {:analysis_event, _}}, 100
  end

  test "a run that ended is answered from its stream, once", ctx do
    begin(ctx)
    gone(ctx)
    DurableRun.update(ctx.id, %{"partition" => "h0a"})
    append(ctx, [failed("fails"), finished(%{pass: 2, fail: 1})])
    File.write!(DurableRun.exit_path(ctx.id), "2\n")

    state = ctx |> boot() |> poll()

    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["status"] == "ok"
    assert payload["result"]["stats"] == %{"tests" => 3, "failures" => 1}
    assert payload["result"]["execution_status"] == "failure"

    assert [%{"name" => "fails", "line" => 4, "message" => "boom"}] =
             payload["result"]["diagnostics"]

    assert payload["result"]["partition"] == "h0a"

    poll(state)
    refute_receive {:"$gen_cast", {:analysis_result, _}}, 100
  end

  test "a run that ended mid-suite is an error, never a pass", ctx do
    begin(ctx)
    gone(ctx)
    append(ctx, [%{event: "test_passed", name: "passes"}])

    ctx |> boot() |> poll()

    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["status"] == "error"
    assert payload["error"] =~ "without a complete suite result"
  end

  test "a run that finished its suite but left no exit status is an error", ctx do
    begin(ctx)
    gone(ctx)
    append(ctx, [finished(%{pass: 1})])

    ctx |> boot() |> poll()

    assert_receive {:"$gen_cast", {:analysis_result, %{"status" => "error"} = payload}}
    assert payload["error"] =~ "without a recorded exit status"
  end

  test "a run that never got a process is answered once it is stale", ctx do
    begin(ctx)
    state = boot(ctx)

    # Still starting: its port may be opening now.
    poll(state)
    refute_receive {:"$gen_cast", {:analysis_result, _}}, 100

    stale = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
    DurableRun.update(ctx.id, %{"started_at" => stale})
    poll(state)

    assert_receive {:"$gen_cast", {:analysis_result, %{"status" => "error"}}}
  end

  test "an answer the server never took is sent again by the next harness", ctx do
    manifest = begin(ctx, [ctx.id + 1])

    DurableRun.complete(manifest, [
      %{"run_id" => ctx.id, "status" => "ok"},
      %{"run_id" => ctx.id + 1, "status" => "ok"}
    ])

    {:ok, manifest} = DurableRun.read_manifest(ctx.id)
    {:pending, _} = DurableRun.acknowledge(manifest, ctx.id)

    state = ctx |> boot() |> poll()

    assert_receive {:"$gen_cast", {:analysis_result, %{"run_id" => id}}}
    assert id == ctx.id + 1
    refute_receive {:"$gen_cast", {:analysis_result, _}}, 100

    poll(state)
    refute_receive {:"$gen_cast", {:analysis_result, _}}, 100
  end

  test "a run is forgotten only when every run tied to it is acknowledged", ctx do
    manifest = begin(ctx, [ctx.id + 1])
    DurableRun.complete(manifest, [%{"run_id" => ctx.id}, %{"run_id" => ctx.id + 1}])
    state = ctx |> boot() |> poll()

    {:noreply, state} = AnalysisServer.handle_cast({:acknowledge, ctx.id}, state)
    assert Map.has_key?(state.recovering, ctx.id)
    assert {:ok, _} = DurableRun.read_manifest(ctx.id)

    {:noreply, state} = AnalysisServer.handle_cast({:acknowledge, ctx.id + 1}, state)
    assert state.recovering == %{}
    assert {:error, :enoent} = DurableRun.read_manifest(ctx.id)
  end

  test "the queue waits behind an adopted run", ctx do
    begin(ctx)
    live_process(ctx)

    {:noreply, state} =
      AnalysisServer.handle_cast(
        {:enqueue, [%{"run_id" => ctx.id + 5, "source" => "credo", "args" => []}]},
        boot(ctx)
      )

    assert state.running == nil
    assert [%{run_id: queued}] = state.queue
    assert queued == ctx.id + 5
  end

  test "a run this harness answered as it finished is not answered again by its poll", ctx do
    manifest = begin(ctx)
    state = boot(ctx)

    # What `deliver/4` writes for the run it just answered, read here before
    # its `:track_completed` arrives.
    DurableRun.complete(manifest, [%{"run_id" => ctx.id}])
    poll(state)

    refute_receive {:"$gen_cast", {:analysis_result, _}}, 100
  end

  test "cancelling an adopted run stops its process and answers every tied run", ctx do
    begin(ctx, [ctx.id + 1])
    live_process(ctx)
    {:ok, manifest} = DurableRun.read_manifest(ctx.id)
    state = boot(ctx)

    assert {:reply, :ok, state} =
             AnalysisServer.handle_call({:cancel_run, ctx.id + 1}, self(), state)

    for id <- [ctx.id, ctx.id + 1] do
      assert_receive {:"$gen_cast",
                      {:analysis_result, %{"run_id" => ^id, "status" => "cancelled"}}}
    end

    assert state.recovering == %{}
    refute DurableRun.alive?(manifest)
    assert {:error, :enoent} = DurableRun.read_manifest(ctx.id)
  end

  test "a project whose client_utils writes no event stream is not run durably" do
    root = Path.join(System.tmp_dir!(), "streams-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    refute DurableRun.streams?(root)

    source = Path.join(root, "deps/client_utils/lib/client_utils/test_formatter/event_stream.ex")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "")
    assert DurableRun.streams?(root)

    File.rm_rf!(Path.join(root, "deps"))

    beam =
      Path.join(
        root,
        "_build/analyzer/test/lib/client_utils/ebin/Elixir.ClientUtils.TestFormatter.EventStream.beam"
      )

    File.mkdir_p!(Path.dirname(beam))
    File.write!(beam, "")
    assert DurableRun.streams?(root), "a path dep has no deps/ entry, only its build"
  end

  test "advancing the cursor keeps what the launch wrote after it was read", ctx do
    begin(ctx)
    {:ok, read_before_attach} = DurableRun.read_manifest(ctx.id)
    live_process(ctx)

    DurableRun.advance(read_before_attach, %{"a" => 1})

    assert {:ok, %{"status" => "running", "pid" => pid, "offsets" => %{"a" => 1}}} =
             DurableRun.read_manifest(ctx.id)

    assert is_integer(pid)
  end

  test "a sharded run is answered once every shard that ran has finished", ctx do
    begin(ctx)
    gone(ctx)
    File.write!(DurableRun.exit_path(ctx.id), "2\n")
    shard = fn i, events -> Enum.map(events, &Map.merge(&1, %{shard: i, shards: 2})) end

    File.write!(
      DurableRun.stream_path(ctx.id) <> ".shard-1",
      Enum.map_join(shard.(1, [finished(%{pass: 1})]), &(Jason.encode!(&1) <> "\n"))
    )

    File.write!(
      DurableRun.stream_path(ctx.id) <> ".shard-2",
      Enum.map_join(
        shard.(2, [failed("fails"), finished(%{fail: 1})]),
        &(Jason.encode!(&1) <> "\n")
      )
    )

    ctx |> boot() |> poll()

    assert_receive {:"$gen_cast", {:analysis_result, %{"status" => "ok"} = payload}}
    assert payload["result"]["stats"] == %{"tests" => 2, "failures" => 1}
  end
end
