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

  test "released stream events preserve invalid failures and incomplete records" do
    id = System.unique_integer([:positive])
    on_exit(fn -> DurableRun.cleanup(id) end)
    manifest = DurableRun.begin_run(id, "/example", "exunit", [], "abc123")
    path = DurableRun.stream_path(id) <> ".shard-1"

    events = [
      %{event: "suite_started", seq: 1, shard: 1, shards: 1},
      %{event: "test_started", seq: 2, shard: 1, shards: 1, name: "excluded"},
      %{event: "test_excluded", seq: 3, shard: 1, shards: 1, name: "excluded"},
      %{
        event: "test_invalid",
        seq: 4,
        shard: 1,
        shards: 1,
        file: "test/tiny_test.exs",
        line: 13,
        failure_line: 14,
        name: "invalid",
        message: "boom",
        duration: 0.251
      },
      %{
        event: "suite_finished",
        seq: 5,
        shard: 1,
        shards: 1,
        pass: 0,
        fail: 0,
        skip: 0,
        excluded: 1,
        invalid: 1
      }
    ]

    [first | rest] = events
    File.write!(path, Jason.encode!(first) <> "\n" <> "{\"event\":\"test_started\"")
    assert {[decoded], offsets} = DurableRun.stream_events(manifest)
    assert decoded["event"] == "suite_started"
    assert offsets[path] == byte_size(Jason.encode!(first)) + 1

    File.write!(path, "}\n" <> Enum.map_join(rest, "", &(Jason.encode!(&1) <> "\n")), [:append])
    assert {remaining, _} = DurableRun.stream_events(manifest, offsets)

    assert Enum.map(remaining, & &1["event"]) == [
             "test_started",
             "test_started",
             "test_excluded",
             "test_invalid",
             "suite_finished"
           ]

    assert DurableRun.live_event(Enum.at(remaining, 3))["state"] == "invalid"
    assert DurableRun.live_event(Enum.at(remaining, 3))["duration"] == 0.251

    File.write!(DurableRun.exit_path(id), "1")
    assert {:ok, result} = DurableRun.completed_result(manifest)
    assert result["stats"] == %{"tests" => 2, "failures" => 1}
    assert [%{"line" => 14, "message" => "boom"}] = result["diagnostics"]
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

  test "cancelling a durable run terminates its OS command" do
    id = System.unique_integer([:positive])
    DurableRun.begin_run(id, File.cwd!(), "exunit", [], "abc123")

    on_exit(fn ->
      id |> DurableRun.read_manifest() |> cancel_if_attached()
      DurableRun.cleanup(id)
    end)

    env =
      CodeMySpec.ExecutionContexts.ExecutionContext.new(:local, File.cwd!(),
        metadata: %{durable_run: id}
      )

    task =
      Task.async(fn -> CodeMySpec.ExecutionContexts.cmd(env, "/bin/sh", ["-c", "sleep 30"]) end)

    manifest = await_attached_manifest(id, 50)
    assert DurableRun.alive?(manifest)
    assert :ok = DurableRun.cancel(manifest)
    assert {:ok, {_output, status}} = Task.yield(task, 2_000)
    assert status != 0
    refute DurableRun.alive?(manifest)
  end

  defp cancel_if_attached({:ok, manifest}), do: DurableRun.cancel(manifest)
  defp cancel_if_attached(_), do: :ok

  defp await_attached_manifest(_id, 0), do: flunk("durable child did not attach")

  defp await_attached_manifest(id, attempts),
    do: await_attached_manifest(id, attempts, DurableRun.read_manifest(id))

  defp await_attached_manifest(_id, _attempts, {:ok, %{"status" => "running"} = manifest}),
    do: manifest

  defp await_attached_manifest(id, attempts, _unattached) do
    Process.sleep(20)
    await_attached_manifest(id, attempts - 1)
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
