defmodule CodeMySpecSpex.Story839.Criterion3444Spex do
  @moduledoc """
  Story 839 — Model and system share one analysis run record.
  Criterion 3444 — A duplicate request for a running source receives the
  result of the next run, not the current one.

  Same rule and mechanism as criterion 3439, recorded as its own scenario:
  a request arriving while its source is executing is tied to a fresh run
  scheduled behind the current one, not superseded with a synthetic status.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects,
    only: [ensure_harness_supervisor_started: 0, project_dir: 0, stop_project: 1]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarness.Projects
  alias CmsHarnessTest.BlockingProject
  alias CmsHarnessTest.FakeServer

  spex "A duplicate request for a running source receives the next run's real result" do
    scenario "spex is running when a second request for spex arrives" do
      given_ "a working copy whose compiler analyzer blocks until told to proceed", context do
        ensure_harness_supervisor_started()
        project = project_dir()
        marker = BlockingProject.make_blocking(project.root)
        on_exit(fn -> stop_project(project.root) end)

        FakeServer.start()
        {:ok, _pid} = Projects.ensure_started(project.root)
        await_connected(project.root)

        {:ok, Map.merge(context, %{project: project, marker: marker})}
      end

      given_ "a run is currently executing for that working copy", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "compiler", "args" => []}])
        BlockingProject.await_started(context.project.root)

        {:ok, context}
      end

      when_ "a second request for the same source arrives before it finishes", context do
        FakeServer.request_analysis([%{"run_id" => 2, "source" => "compiler", "args" => []}])
        refute_result_yet(2, 300)

        {:ok, context}
      end

      then_ "the second requester receives the fresh run's real result, not an empty status",
            context do
        BlockingProject.unblock(context.marker)

        result_1 = await_result(1)
        result_2 = await_result(2)

        assert result_1["status"] == "ok"

        assert_same_real_result(result_1, result_2)

        {:ok, context}
      end
    end
  end
end
