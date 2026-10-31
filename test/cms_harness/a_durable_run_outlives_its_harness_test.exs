defmodule CmsHarness.ADurableRunOutlivesItsHarnessTest do
  @moduledoc """
  An exunit or spex run survives the harness that started it (issue 128c1b27).

  A real `mix test` (or `mix spex`, sexy_spex's task) of a three-test project,
  launched through the `AnalysisServer` the way the server's request is. The
  run is a node of its own, linked to this one through `CmsHarness.RunLink`.
  The queue, its task and the link are killed mid-run, which is what a
  harness restart does to them; a fresh queue claims the run from its record,
  the run rejoins the restarted link and is adopted, and its one result is
  answered from what it wrote. A run whose node dies with no harness watching
  is answered as an error, never as a pass.

  The test BEAM becomes the harness node (distribution started by the link,
  as in the harness). A fake channel is registered where `ChannelClient` is
  looked up by root.
  """
  use ExUnit.Case, async: false

  # Three real `mix` runs of a fixture project, compiled cold.
  @moduletag timeout: :timer.minutes(5)

  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Sync
  alias CodeMySpec.Analysis.Runners
  alias CodeMySpec.DurableRun

  @failing_test_line 6
  @failing_spex_line 16

  setup do
    root = Path.join(System.tmp_dir!(), "durable-run-#{System.unique_integer([:positive])}")
    write_project(root)
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    # Clear of the ids a real harness on this machine keeps records for.
    run_id = 2_000_000_000 + System.unique_integer([:positive])

    # The run waits for a harness forever; it is stopped as an offboarded
    # copy's runs are.
    on_exit(fn ->
      CmsHarness.RunLink.cancel_copy(root)
      DurableRun.cleanup(run_id)
      File.rm_rf(root)
    end)

    %{root: root, run_id: run_id}
  end

  test "a fresh harness adopts the surviving run and answers it once", ctx do
    harness = start_harness(ctx.root, :first)
    enqueue(ctx, "exunit")
    node = await_linked_run(ctx)

    kill_harness(ctx.root, harness)
    assert Node.ping(node) == :pong, "the run died with its harness"

    start_harness(ctx.root, :second)
    assert eventually(fn -> ctx.run_id in AnalysisServer.in_flight(ctx.root) end)
    File.write!(Path.join(ctx.root, "gate"), "")

    assert_receive {:"$gen_cast", {:analysis_result, %{"run_id" => run_id} = payload}},
                   60_000,
                   "no result; the run printed: " <> run_output(ctx.run_id)

    assert run_id == ctx.run_id
    assert payload["status"] == "ok", inspect(payload)
    raw = payload["result"]
    assert raw["exit_status"] != 0
    assert raw["execution_status"] == "failure"
    assert %{"tests" => 3, "failures" => 1} = raw["stats"]

    # As the formatter's results file names it, the same as a live result.
    assert [%{"name" => "test fails", "file" => "test/tiny_test.exs"} = failure] =
             raw["diagnostics"]

    assert failure["line"] == @failing_test_line
    assert failure["message"] =~ "Assertion with == failed"
    assert raw["partition"] == "durablea", "the database it ran on, as a live result says"

    assert raw["output"] =~ "Result: 2/3 passed",
           "printed after its harness died: " <> raw["output"]

    # Read as the server reads a harness's result.
    assert {:ok, %{problems: [problem], exit_status: status}} = Runners.from_raw("exunit", raw)
    assert status == raw["exit_status"]
    assert problem.file_path == "test/tiny_test.exs"

    # The run exits once its exit is acknowledged; answered once, then
    # forgotten when the server takes it.
    assert eventually(fn -> Node.ping(node) == :pang end), "the run never exited"
    refute_receive {:"$gen_cast", {:analysis_result, _}}, 1_000
    AnalysisServer.acknowledge(ctx.root, ctx.run_id)
    assert eventually(fn -> AnalysisServer.idle?(ctx.root) end)
    assert {:error, :enoent} = DurableRun.read_manifest(ctx.run_id)
  end

  test "a spex run is adopted and answered the same way", ctx do
    harness = start_harness(ctx.root, :first)
    enqueue(ctx, "spex")
    node = await_linked_run(ctx)

    kill_harness(ctx.root, harness)
    assert Node.ping(node) == :pong, "the run died with its harness"

    start_harness(ctx.root, :second)
    assert eventually(fn -> ctx.run_id in AnalysisServer.in_flight(ctx.root) end)
    File.write!(Path.join(ctx.root, "gate"), "")

    assert_receive {:"$gen_cast", {:analysis_result, %{"run_id" => run_id} = payload}},
                   60_000,
                   "no result; the run printed: " <> run_output(ctx.run_id)

    assert run_id == ctx.run_id
    assert payload["status"] == "ok", inspect(payload)
    raw = payload["result"]
    assert raw["exit_status"] != 0
    assert raw["partition"] == "durables"

    assert [%{"spex" => "fails", "file" => "test/spex/tiny_spex.exs"} = failure] =
             raw["diagnostics"]

    assert failure["line"] == @failing_spex_line
    assert failure["message"] =~ "Assertion with == failed"

    assert {:ok, %{problems: [problem]}} = Runners.from_raw("spex", raw)
    assert problem.file_path == "test/spex/tiny_spex.exs"

    refute_receive {:"$gen_cast", {:analysis_result, _}}, 1_000
  end

  test "a run whose node died with no harness watching is an error, not a pass", ctx do
    harness = start_harness(ctx.root, :first)
    enqueue(ctx, "exunit")
    node = await_linked_run(ctx)

    kill_harness(ctx.root, harness)
    :rpc.cast(node, :erlang, :halt, [137])
    assert eventually(fn -> Node.ping(node) == :pang end)

    %{server: server} = start_harness(ctx.root, :second)
    # What the grace timer sends, now rather than in a minute.
    send(server, {:recovery_check, ctx.run_id})

    assert_receive {:"$gen_cast", {:analysis_result, %{"run_id" => run_id} = payload}},
                   30_000

    assert run_id == ctx.run_id
    assert payload["status"] == "error"
    assert payload["error"] =~ "node went away"
    refute Map.has_key?(payload, "result")
  end

  defp enqueue(ctx, source) do
    AnalysisServer.enqueue(ctx.root, [
      %{"run_id" => ctx.run_id, "source" => source, "args" => []}
    ])
  end

  # What a harness holds for one checkout: its task supervisor and its queue.
  defp start_harness(root, id) do
    sup =
      start_supervised!(
        Supervisor.child_spec({Task.Supervisor, name: Sync.task_supervisor(root)},
          id: {:tasks, id},
          restart: :temporary
        )
      )

    server =
      start_supervised!(
        Supervisor.child_spec({AnalysisServer, project: %{root: root}},
          id: {:analysis, id},
          restart: :temporary
        )
      )

    %{sup: sup, server: server}
  end

  # Killed, not stopped: a restarted harness runs no cleanup. The task dies
  # with its supervisor and closes the port the run was started through.
  # The harness's link goes too, and comes back empty as a new harness's would.
  defp kill_harness(root, %{sup: sup, server: server}) do
    refs = Enum.map([server, sup], &Process.monitor/1)
    Enum.each([server, sup], &Process.exit(&1, :kill))
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
    restart_run_link()

    assert eventually(fn ->
             Registry.lookup(CmsHarness.Registry, {:analysis, root}) == [] and
               GenServer.whereis(Sync.task_supervisor(root)) == nil
           end)
  end

  # Through its supervisor rather than killed: a kill spends the harness
  # supervisor's restart budget, which every child in the suite shares, and a
  # crash elsewhere in the same seconds took the whole tree down.
  defp restart_run_link do
    :ok = Supervisor.terminate_child(CmsHarness.Supervisor, CmsHarness.RunLink)
    {:ok, _pid} = Supervisor.restart_child(CmsHarness.Supervisor, CmsHarness.RunLink)
  end

  # The run is linked (its node answers and it is inside its test file),
  # and held at the gate until the test opens it.
  defp await_linked_run(ctx) do
    run_id = ctx.run_id

    assert_receive {:"$gen_cast",
                    {:analysis_event,
                     %{"run_id" => ^run_id, "event" => %{"event" => "file_started"}}}},
                   120_000,
                   "the run never linked: " <> run_output(run_id)

    {:ok, %{"node" => node}} = DurableRun.read_manifest(run_id)
    node = String.to_atom(node)
    assert Node.ping(node) == :pong
    node
  end

  defp run_output(run_id), do: run_id |> DurableRun.output_path() |> File.read() |> output()

  defp output({:ok, output}), do: output
  defp output(_missing), do: "(no output)"

  # A project with no deps of its own, its formatter and `mix spex` loaded from
  # this build, and `deps/client_utils` naming the source of the client_utils
  # it runs.
  defp write_project(root) do
    File.mkdir_p!(Path.join(root, "test/spex"))
    File.mkdir_p!(Path.join(root, "deps"))
    File.mkdir_p!(Path.join(root, ".claude"))
    File.ln_s!(Mix.Project.deps_paths()[:client_utils], Path.join(root, "deps/client_utils"))

    ebins = Enum.map([:client_utils, :jason, :sexy_spex], &Path.join(:code.lib_dir(&1), "ebin"))

    # `prune_code_paths: false` keeps these paths once `mix spex` compiles.
    File.write!(Path.join(root, "mix.exs"), """
    Enum.each(#{inspect(ebins)}, &Code.prepend_path/1)

    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.1.0", deps: [], prune_code_paths: false]
    end
    """)

    File.write!(
      Path.join(root, ".claude/settings.local.json"),
      ~s({"env": {"MIX_TEST_PARTITION": "durable"}})
    )

    File.write!(Path.join(root, "test/test_helper.exs"), """
    Enum.each(#{inspect(ebins)}, &Code.prepend_path/1)
    ExUnit.start()
    """)

    gate = Path.join(root, "gate")

    # `@failing_test_line` is the line of the failing test below.
    File.write!(Path.join(root, "test/tiny_test.exs"), """
    defmodule TinyTest do
      use ExUnit.Case

      test "passes", do: assert(1 + 1 == 2)

      test "fails" do
        assert 1 + 1 == 3
      end

      test "waits for the gate" do
        opened? = Enum.any?(1..3_000, fn _ -> File.exists?(#{inspect(gate)}) or (Process.sleep(20) && false) end)
        assert opened?, "the gate never opened"
      end
    end
    """)

    # `@failing_spex_line` is the line of the failing assertion below.
    File.write!(Path.join(root, "test/spex/tiny_spex.exs"), """
    defmodule TinySpex do
      use SexySpex

      spex "passes" do
        scenario "it holds" do
          then_ "two is two", context do
            assert 1 + 1 == 2
            {:ok, context}
          end
        end
      end

      spex "fails" do
        scenario "it does not hold" do
          then_ "two is three", context do
            assert 1 + 1 == 3
            {:ok, context}
          end
        end
      end

      spex "waits for the gate" do
        scenario "the gate opens" do
          then_ "it is there", context do
            opened? = Enum.any?(1..3_000, fn _ -> File.exists?(#{inspect(gate)}) or (Process.sleep(20) && false) end)
            assert opened?, "the gate never opened"
            {:ok, context}
          end
        end
      end
    end
    """)
  end

  defp eventually(fun, attempts \\ 200) do
    Enum.find_value(1..attempts, false, fn _ ->
      fun.() ||
        (
          Process.sleep(50)
          nil
        )
    end)
  end
end
