defmodule CodeMySpecSpex.Story1142.Criterion2369Spex do
  @moduledoc """
  Story 1142 — A test run survives its harness and is answered once.
  Criterion 2369 — A run whose node dies while no harness watches is reported
  as gone, never as passed.

  The harness that comes back claims the run it finds recorded; when the
  run's node no longer answers, the run is reported as gone, with no result.
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

  spex "A run whose node dies while no harness watches is reported as gone, never as passed",
    criterion: 2369 do
    scenario "the run is killed while its harness is restarting" do
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

      when_ "his harness restarts, and the run dies before it is back", context do
        stop_project(context.project.root)
        :ok = Supervisor.terminate_child(CmsHarness.Supervisor, CmsHarness.RunLink)

        :ok = ClusteredProject.kill(context.os_pid)
        assert ClusteredProject.gone_within?(context.os_pid, 10_000)

        {:ok, _pid} = Supervisor.restart_child(CmsHarness.Supervisor, CmsHarness.RunLink)

        {:ok, _pid} = ensure_started(context.project.root)
        await_connected(context.project.root)
        {:ok, context}
      end

      then_ "the run is reported as gone, with no result", context do
        result = await_result(1)

        assert result["status"] == "error", inspect(result)
        assert result["error"] =~ "node went away"
        refute Map.has_key?(result, "result"), "a run that died is never answered as passed"
        {:ok, context}
      end
    end
  end
end
