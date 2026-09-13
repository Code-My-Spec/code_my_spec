defmodule CodeMySpecSpex.Story839.Criterion3443Spex do
  @moduledoc """
  Story 839 — Model and system share one analysis run record.
  Criterion 3443 — A second source queues behind the first rather than
  running concurrently.

  The scenario Example Mapping recorded for the same rule as criterion 3438
  ("at most one analyzer run executes at a time for a given working copy"):
  compiler running, credo arrives, credo queues and only starts once
  compiler finishes. Kept as its own file — same rule, same guarantee, a
  distinct criterion record on the story — but written independently rather
  than copied, so a change to one cannot silently leave the other
  unverified.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects,
    only: [ensure_harness_supervisor_started: 0, project_dir: 0, stop_project: 1]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarness.Projects
  alias CmsHarnessTest.BlockingProject
  alias CmsHarnessTest.FakeServer

  # See criterion 3438's spex for why: credo's own "not installed" error is
  # this scenario's expected proof it never ran early, not a defect.
  spex "Given compiler is currently running, credo queues and only starts once it finishes",
    fail_on_error_logs: false do
    scenario "credo arrives while compiler is still executing" do
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

      given_ "compiler is currently running", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "compiler", "args" => []}])
        BlockingProject.await_started(context.project.root)

        {:ok, context}
      end

      when_ "a request for credo on the same working copy arrives", context do
        FakeServer.request_analysis([%{"run_id" => 2, "source" => "credo", "args" => []}])

        {:ok, context}
      end

      then_ "credo queues rather than starting immediately", context do
        refute_result_yet(2, 300)

        {:ok, context}
      end

      then_ "credo only starts once compiler finishes", context do
        BlockingProject.unblock(context.marker)

        compiler_result = await_result(1)
        credo_result = await_result(2)

        assert compiler_result["status"] == "ok"
        assert credo_result["status"] == "error"
        assert credo_result["error"] =~ "credo is not installed"

        {:ok, context}
      end
    end
  end
end
