defmodule CodeMySpecSpex.Story1142.Criterion2366Spex do
  @moduledoc """
  Story 1142 — A test run survives its harness and is answered once.
  Criterion 2366 — Sam's harness restarts mid-run and the next one adopts the run.

  The run is a node linked to the harness that started it. When that harness
  restarts, the run keeps going, finds the harness that comes back, is
  adopted, and is answered once, by the new harness.
  """

  # One harness tree and one machine-wide slot table per node.
  use CodeMySpecSpex.Case, async: false

  import CmsHarnessTest.Projects,
    only: [
      ensure_harness_supervisor_started: 0,
      project_dir: 0,
      stop_project: 1,
      ensure_started: 1
    ]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarnessTest.ClusteredProject
  alias CmsHarnessTest.FakeServer

  spex "Sam's harness restarts mid-run and the next one adopts the run", criterion: 2366 do
    scenario "the harness restarts while the suite is running" do
      given_ "Sam's working copy is served by his harness", context do
        ensure_harness_supervisor_started()
        project = project_dir()
        :ok = ClusteredProject.make(project.root)
        on_exit(fn -> stop_project(project.root) end)

        FakeServer.start()
        {:ok, _pid} = ensure_started(project.root)
        await_connected(project.root)

        {:ok, Map.put(context, :project, project)}
      end

      given_ "Sam's suite is running for his harness", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "exunit", "args" => []}])
        {:ok, Map.put(context, :os_pid, ClusteredProject.await_running(context.project.root))}
      end

      when_ "his harness restarts", context do
        restart_harness(context.project.root)
        {:ok, context}
      end

      then_ "the run kept going through the restart", context do
        assert ClusteredProject.running?(context.os_pid),
               "mix test (os pid #{context.os_pid}) died with the harness that started it"

        {:ok, context}
      end

      then_ "the harness that came back answers it with its real result", context do
        :ok = ClusteredProject.release(context.project.root)
        result = await_result(1)

        assert result["status"] == "ok", inspect(result)
        assert result["result"]["exit_status"] == 0
        assert result["result"]["execution_status"] == "success"
        {:ok, context}
      end

      then_ "and answers it only once", context do
        :ok = refute_result_yet(1, 2_000)
        {:ok, context}
      end
    end
  end

  # What a harness restart does to it: its copy's queue and the node's run
  # link go, and come back empty.
  defp restart_harness(root) do
    stop_project(root)
    link = Process.whereis(CmsHarness.RunLink)
    ref = Process.monitor(link)
    Process.exit(link, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert eventually_restarted(link), "the run link did not come back"

    {:ok, _pid} = ensure_started(root)
    await_connected(root)
  end

  defp eventually_restarted(old, attempts \\ 100) do
    Enum.any?(1..attempts, fn _ ->
      Process.whereis(CmsHarness.RunLink) not in [nil, old] or
        (
          Process.sleep(20)
          false
        )
    end)
  end
end
