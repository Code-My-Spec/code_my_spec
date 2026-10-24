defmodule CodeMySpecSpex.Story1142.Criterion2368Spex do
  @moduledoc """
  Story 1142 — A run never outlives the harness that started it.
  Criterion 2368 — Sam cancels a run.

  Cancelling stops the run where it is and records it as cancelled, not as
  failed or finished.
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

  spex "Sam cancels a run", criterion: 2368 do
    scenario "Sam cancels a suite that is running" do
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

      when_ "Sam cancels it", context do
        FakeServer.push_event("cancel_analysis", %{"run_id" => 1})
        {:ok, context}
      end

      then_ "the run stops and is shown as cancelled", context do
        assert await_result(1, 10_000)["status"] == "cancelled"

        assert ClusteredProject.gone_within?(context.os_pid, 10_000),
               "mix test (os pid #{context.os_pid}) is still running after it was cancelled"

        {:ok, context}
      end
    end
  end
end
