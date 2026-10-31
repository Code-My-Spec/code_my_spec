defmodule CodeMySpec.DurableRunTest do
  @moduledoc """
  The record a harness keeps of each test run, for the next harness to claim
  it after a restart: written when the run starts, found by root, answered
  once, and removed with every file of the run once the server has every
  answer.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.DurableRun

  setup do
    # Clear of the ids a real harness on this machine keeps records for.
    id = 2_000_000_000 + System.unique_integer([:positive])
    on_exit(fn -> DurableRun.cleanup(id) end)
    %{id: id, root: "/durable-run-test-#{id}"}
  end

  test "a started run is recorded, found by its root, and updated", ctx do
    DurableRun.begin_run(ctx.id, ctx.root, "exunit", ["test/a_test.exs"], "abc123", [ctx.id + 1])

    assert [manifest] = DurableRun.for_root(ctx.root)

    assert %{
             "run_id" => run_id,
             "source" => "exunit",
             "args" => ["test/a_test.exs"],
             "status" => "running",
             "tied_run_ids" => [tied]
           } = manifest

    assert run_id == ctx.id and tied == ctx.id + 1
    assert DurableRun.for_root("/elsewhere-#{ctx.id}") == []

    :ok = DurableRun.update(ctx.id, %{"node" => "cms_run_1@127.0.0.1", "partition" => "h0a"})

    assert {:ok, %{"node" => "cms_run_1@127.0.0.1", "status" => "running"}} =
             DurableRun.read_manifest(ctx.id)
  end

  test "an answered run keeps each payload until the server acknowledges it", ctx do
    manifest = DurableRun.begin_run(ctx.id, ctx.root, "spex", [], "abc123", [ctx.id + 1])
    File.write!(DurableRun.results_path(ctx.id, ".jsonl"), "")
    File.write!(DurableRun.output_path(ctx.id) <> ".shard-1", "shard 1's output")

    manifest = DurableRun.complete(manifest, [%{"run_id" => ctx.id}, %{"run_id" => ctx.id + 1}])
    assert [%{"status" => "completed"}] = DurableRun.for_root(ctx.root)

    assert {:pending, manifest} = DurableRun.acknowledge(manifest, ctx.id)
    assert DurableRun.unacknowledged_payloads(manifest) == [%{"run_id" => ctx.id + 1}]

    assert :complete = DurableRun.acknowledge(manifest, ctx.id + 1)
    assert {:error, :enoent} = DurableRun.read_manifest(ctx.id)
    refute File.exists?(DurableRun.output_path(ctx.id))
    refute File.exists?(DurableRun.output_path(ctx.id) <> ".shard-1")
    refute File.exists?(DurableRun.results_path(ctx.id, ".jsonl"))
  end

  test "records go where the app says, not the machine's shared state directory" do
    configured = Application.fetch_env!(:code_my_spec, :durable_run_dir)

    assert DurableRun.dir() == configured
    refute String.starts_with?(DurableRun.dir(), CodeMySpec.Paths.local_state_dir())
  end

  describe "links?/1" do
    setup ctx do
      root = Path.join(System.tmp_dir!(), "links-#{ctx.id}")
      on_exit(fn -> File.rm_rf(root) end)
      %{project: root}
    end

    test "a project with no client_utils does not link", ctx do
      refute DurableRun.links?(ctx.project)
    end

    test "a fetched client_utils with the run session links", ctx do
      write(ctx.project, "deps/client_utils/lib/client_utils/run_link/session.ex")
      assert DurableRun.links?(ctx.project)
    end

    test "a path dep links through the analyzer's build of it", ctx do
      # `MIX_BUILD_PATH` is taken as given, with no env appended.
      write(
        ctx.project,
        "_build/analyzer/lib/client_utils/ebin/Elixir.ClientUtils.RunLink.Session.beam"
      )

      assert DurableRun.links?(ctx.project)
    end

    test "an older client_utils, with no session, does not", ctx do
      write(ctx.project, "deps/client_utils/lib/client_utils/run_link.ex")
      refute DurableRun.links?(ctx.project)
    end
  end

  defp write(root, path) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end
end
