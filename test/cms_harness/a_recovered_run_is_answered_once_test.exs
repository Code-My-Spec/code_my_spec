defmodule CmsHarness.ARecoveredRunIsAnsweredOnceTest do
  @moduledoc """
  What a restarted harness does with each test run the previous one recorded
  (issue 128c1b27): claims it, so the run's rejoin is adopted; answers it from
  its results and output files once its exit arrives, once; reports it as gone
  when its node no longer answers, never as a pass; and resends an answer the
  server never acknowledged. A project whose client_utils cannot link a run is
  refused, not run another way.

  Driven through the queue's own callbacks on records written to disk. A fake
  `CmsHarness.RunLink` answers the claim in place of the harness supervisor's
  own, so no distribution is started; a
  fake channel is registered where `ChannelClient` is looked up by root.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Sync
  alias CodeMySpec.DurableRun

  setup do
    root = "/recovered-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    # Clear of the ids a real harness on this machine keeps records for.
    id = 2_000_000_000 + System.unique_integer([:positive])
    on_exit(fn -> DurableRun.cleanup(id) end)
    %{root: root, id: id}
  end

  # Answers `claim/3` as the real one does, and says what it was asked.
  defp fake_run_link do
    test = self()

    # Unlinked: it must still hold the name when `on_exit` puts the real one back.
    pid =
      spawn(fn ->
        Stream.repeatedly(fn ->
          receive do
            {:"$gen_call", from, request} ->
              send(test, {:run_link, request})
              GenServer.reply(from, :ok)
          end
        end)
        |> Stream.run()
      end)

    # The harness supervisor's own stands aside for the test, and is put back.
    real = Process.whereis(CmsHarness.RunLink)
    true = Process.unregister(CmsHarness.RunLink)
    Process.register(pid, CmsHarness.RunLink)

    on_exit(fn ->
      true = Process.unregister(CmsHarness.RunLink)
      Process.exit(pid, :kill)
      Process.register(real, CmsHarness.RunLink)
    end)
  end

  defp begin(ctx, source, tied \\ []),
    do: DurableRun.begin_run(ctx.id, ctx.root, source, [], "abc", tied)

  defp boot(ctx) do
    fake_run_link()
    {:ok, state} = AnalysisServer.init(%{root: ctx.root})
    state
  end

  defp exited(state, ctx, status) do
    {:noreply, state} = AnalysisServer.handle_info({:run_exited, ctx.id, status}, state)
    state
  end

  test "a run left by the previous harness is claimed, held, and not queued again", ctx do
    begin(ctx, "exunit", [ctx.id + 1])
    state = boot(ctx)
    {id, root, owner} = {ctx.id, ctx.root, self()}

    assert_received {:run_link, {:expect, ^id, ^root, ^owner}}
    assert {:reply, ids, _} = AnalysisServer.handle_call(:in_flight, self(), state)
    assert Enum.sort(ids) == [ctx.id, ctx.id + 1]

    {:noreply, state} =
      AnalysisServer.handle_cast(
        {:enqueue, [%{"run_id" => ctx.id + 1, "source" => "exunit", "args" => []}]},
        state
      )

    assert state.queue == []
  end

  test "an exunit run that exits is answered from its results file, once", ctx do
    begin(ctx, "exunit")

    File.write!(
      DurableRun.results_path(ctx.id, ".json"),
      Jason.encode!(%{
        "stats" => %{"passes" => 1, "failures" => 1, "pending" => 0, "invalid" => 0, "tests" => 2},
        "tests" => [%{"title" => "passes", "fullTitle" => "ATest: passes", "duration" => 1.0}],
        "failures" => [
          %{
            "title" => "fails",
            "fullTitle" => "ATest: fails",
            "duration" => 1.0,
            "error" => %{"file" => "test/a_test.exs", "line" => 7, "message" => "boom"}
          }
        ],
        "pending" => []
      })
    )

    File.write!(DurableRun.output_path(ctx.id), "compiled\n2 tests, 1 failure\n")
    state = ctx |> boot() |> exited(ctx, 2)

    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["run_id"] == ctx.id
    assert payload["status"] == "ok"
    result = payload["result"]
    assert result["exit_status"] == 2
    assert result["execution_status"] == "failure"
    assert result["stats"]["tests"] == 2
    assert result["output"] =~ "2 tests, 1 failure"

    assert [%{"name" => "fails", "file" => "test/a_test.exs", "line" => 7, "message" => "boom"}] =
             result["diagnostics"]

    exited(state, ctx, 2)
    refute_receive {:"$gen_cast", {:analysis_result, _}}, 100
  end

  test "a spex run is answered from its JSONL with every shard's output", ctx do
    begin(ctx, "spex")

    File.write!(
      DurableRun.results_path(ctx.id, ".jsonl"),
      Jason.encode!(%{
        "spex" => "A spex",
        "scenario" => "it fails",
        "spec_file" => "test/spex/1_a/criterion_1_spex.exs",
        "error" => %{
          "message" => "boom",
          "file" => "test/spex/1_a/criterion_1_spex.exs",
          "line" => 12,
          "stacktrace" => []
        }
      }) <> "\n"
    )

    File.write!(DurableRun.output_path(ctx.id), "runner\n")
    File.write!(DurableRun.output_path(ctx.id) <> ".shard-1", "shard one\n")
    File.write!(DurableRun.output_path(ctx.id) <> ".shard-2", "shard two\n")

    ctx |> boot() |> exited(ctx, 1)

    assert_receive {:"$gen_cast", {:analysis_result, %{"status" => "ok"} = payload}}
    result = payload["result"]
    assert result["exit_status"] == 1
    assert result["output"] =~ "runner"
    assert result["output"] =~ "shard one"
    assert result["output"] =~ "shard two"

    assert [%{"spex" => "A spex", "scenario" => "it fails", "message" => "boom"}] =
             result["diagnostics"]
  end

  test "a run whose node no longer answers is reported as gone, not passed", ctx do
    begin(ctx, "exunit")
    DurableRun.update(ctx.id, %{"node" => "gone_#{ctx.id}@127.0.0.1"})
    state = boot(ctx)

    {:noreply, _state} = AnalysisServer.handle_info({:recovery_check, ctx.id}, state)

    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["status"] == "error"
    assert payload["error"] =~ "node went away"
    refute Map.has_key?(payload, "result")
  end

  test "an answer the server never took is sent again by the next harness", ctx do
    manifest = begin(ctx, "exunit", [ctx.id + 1])

    DurableRun.complete(manifest, [
      %{"run_id" => ctx.id, "status" => "ok"},
      %{"run_id" => ctx.id + 1, "status" => "ok"}
    ])

    {:ok, manifest} = DurableRun.read_manifest(ctx.id)
    {:pending, _} = DurableRun.acknowledge(manifest, ctx.id)

    state = boot(ctx)

    assert_receive {:"$gen_cast", {:analysis_result, %{"run_id" => id}}}
    assert id == ctx.id + 1
    refute_receive {:"$gen_cast", {:analysis_result, _}}, 100
    refute_received {:run_link, _}

    {:noreply, state} = AnalysisServer.handle_cast({:acknowledge, ctx.id + 1}, state)
    assert state.recovering == %{}
    assert {:error, :enoent} = DurableRun.read_manifest(ctx.id)
  end

  test "a project whose client_utils cannot link a run is refused, not run", ctx do
    root = Path.join(System.tmp_dir!(), "no-link-#{ctx.id}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    start_supervised!({Task.Supervisor, name: Sync.task_supervisor(root)})
    start_supervised!({AnalysisServer, project: %{root: root}})

    AnalysisServer.enqueue(root, [%{"run_id" => ctx.id, "source" => "exunit", "args" => []}])

    assert_receive {:"$gen_cast", {:analysis_result, payload}}, 15_000
    assert payload["status"] == "error"
    assert payload["error"] =~ "needs client_utils 0.4.0 or later"
    assert {:error, :enoent} = DurableRun.read_manifest(ctx.id)
  end
end
