defmodule CodeMySpecSpex.Story1142.Criterion2370Spex do
  @moduledoc """
  Story 1142 — A run never outlives the harness that started it.
  Criterion 2370 — Sam's run on Windows stops with its harness.

  The run stops with its harness by the same means on every platform. On
  Windows there are no Unix process groups to signal, so nothing here may
  depend on `CodeMySpec.RunGuard`, which does not start there.
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

  spex "Sam's run on Windows stops with its harness", criterion: 2370 do
    scenario "the harness stops on a machine without Unix process groups" do
      given_ "Sam works on Windows", context do
        ensure_harness_supervisor_started()
        :ok = ClusteredProject.as_on_windows()
        {:ok, context}
      end

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

      when_ "his harness stops", context do
        stop_project(context.project.root)
        {:ok, context}
      end

      then_ "the run stops, as it would on macOS or Linux", context do
        assert ClusteredProject.gone_within?(context.os_pid, 10_000),
               "mix test (os pid #{context.os_pid}) is still running after its harness stopped"

        {:ok, context}
      end
    end
  end
end
