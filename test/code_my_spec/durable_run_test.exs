defmodule CodeMySpec.DurableRunTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.DurableRun

  test "reconstructs a completed sharded run and retains each result until acknowledged" do
    id = System.unique_integer([:positive])
    on_exit(fn -> DurableRun.cleanup(id) end)

    DurableRun.begin_run(id, "/example", "exunit", [], "abc123", [id + 1])

    write_events(id, 1, [
      %{event: "test_passed", shard: 1, shards: 2, name: "passes"},
      %{
        event: "suite_finished",
        shard: 1,
        shards: 2,
        pass: 1,
        fail: 0,
        skip: 0,
        excluded: 0,
        invalid: 0
      }
    ])

    assert {:error, _} = DurableRun.completed_result(%{"run_id" => id, "source" => "exunit"})

    write_events(id, 2, [
      %{
        event: "test_failed",
        shard: 2,
        shards: 2,
        name: "fails",
        file: "test/example_test.exs",
        line: 12,
        message: "boom"
      },
      %{
        event: "suite_finished",
        shard: 2,
        shards: 2,
        pass: 0,
        fail: 1,
        skip: 0,
        excluded: 0,
        invalid: 0
      }
    ])

    File.write!(DurableRun.exit_path(id), "1")
    assert {:ok, result} = DurableRun.completed_result(%{"run_id" => id, "source" => "exunit"})
    assert result["exit_status"] == 1
    assert result["stats"] == %{"tests" => 2, "failures" => 1}
    assert [%{"message" => "boom"}] = result["diagnostics"]

    {:ok, manifest} = DurableRun.read_manifest(id)
    manifest = DurableRun.complete(manifest, [%{"run_id" => id}, %{"run_id" => id + 1}])
    assert {:pending, manifest} = DurableRun.acknowledge(manifest, id)
    assert DurableRun.unacknowledged_payloads(manifest) == [%{"run_id" => id + 1}]
    assert :complete = DurableRun.acknowledge(manifest, id + 1)
    assert {:error, :enoent} = DurableRun.read_manifest(id)
  end

  test "durable command records child identity, output and exit status" do
    id = System.unique_integer([:positive])
    on_exit(fn -> DurableRun.cleanup(id) end)
    DurableRun.begin_run(id, File.cwd!(), "exunit", [], "abc123")

    env =
      CodeMySpec.ExecutionContexts.ExecutionContext.new(:local, File.cwd!(),
        metadata: %{durable_run: id}
      )

    assert {"ready\n", 0} =
             CodeMySpec.ExecutionContexts.cmd(env, "/bin/sh", [
               "-c",
               "sleep 0.2; printf 'ready\n'"
             ])

    assert {:ok, manifest} = DurableRun.read_manifest(id)
    assert is_integer(manifest["pid"])
    assert is_binary(manifest["identity"])
    assert {:ok, "0\n"} = File.read(DurableRun.exit_path(id))
    assert {:ok, "ready\n"} = File.read(DurableRun.output_path(id))
  end

  test "a new manifest remains pending while the child PID is being attached" do
    id = System.unique_integer([:positive])
    root = "/example-#{id}"
    on_exit(fn -> DurableRun.cleanup(id) end)
    manifest = DurableRun.begin_run(id, root, "exunit", [], "abc123")

    state = %{
      project: %{root: root},
      running: nil,
      queue: [],
      pending_cleanups: [],
      recovering: %{id => manifest}
    }

    assert {:noreply, next} = CmsHarness.Project.AnalysisServer.handle_info(:poll_recovery, state)
    assert next.recovering[id]["status"] == "starting"
    assert {:ok, %{"status" => "starting"}} = DurableRun.read_manifest(id)
  end

  test "server recovery delivers a completed durable run" do
    id = System.unique_integer([:positive])
    root = "/example-#{id}"
    on_exit(fn -> DurableRun.cleanup(id) end)
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)

    DurableRun.begin_run(id, root, "exunit", [], "abc123")

    File.write!(
      DurableRun.stream_path(id),
      Jason.encode!(%{
        event: "suite_finished",
        pass: 1,
        fail: 0,
        skip: 0,
        excluded: 0,
        invalid: 0
      }) <> "\n"
    )

    File.write!(DurableRun.exit_path(id), "0")
    {:ok, manifest} = DurableRun.read_manifest(id)
    DurableRun.advance(Map.put(manifest, "status", "running"), %{})

    {:ok, state} = CmsHarness.Project.AnalysisServer.init(%{root: root})
    assert {:noreply, next} = CmsHarness.Project.AnalysisServer.handle_info(:poll_recovery, state)
    assert next.recovering[id]["status"] == "completed"
    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["run_id"] == id
    assert payload["status"] == "ok"
    assert payload["result"]["stats"] == %{"tests" => 1, "failures" => 0}
  end

  defp write_events(id, shard, events) do
    path = DurableRun.stream_path(id) <> ".shard-#{shard}"
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end
end
