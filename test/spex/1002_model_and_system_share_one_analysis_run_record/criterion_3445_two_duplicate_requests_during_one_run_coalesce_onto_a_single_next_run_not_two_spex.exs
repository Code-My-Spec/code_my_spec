defmodule CodeMySpecSpex.Story839.Criterion3445Spex do
  @moduledoc """
  Story 839 — Model and system share one analysis run record.
  Criterion 3445 — Two duplicate requests during one run coalesce onto a
  single next run, not two.

  Tying prevents an empty answer; it must not reintroduce the pile-up tying
  exists instead of (397 superseded runs against 25 completed in ninety
  minutes on Broken Oaths 2026-09-08). Two requests arriving while a source
  is running have to share one scheduled next run, not one apiece — asserted
  on how many times the analyzer actually executed, because two requests
  each answered correctly, from two separately-scheduled runs, would look
  identical to this scenario's other assertions and only differ in cost.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects,
    only: [ensure_harness_supervisor_started: 0, project_dir: 0, stop_project: 1]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarness.Projects
  alias CmsHarnessTest.BlockingProject
  alias CmsHarnessTest.FakeServer

  spex "Two duplicate requests during one run coalesce onto a single next run" do
    scenario "two more requests for compiler arrive while the first is still executing" do
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

      when_ "two more requests for the same source arrive before it finishes", context do
        FakeServer.request_analysis([%{"run_id" => 2, "source" => "compiler", "args" => []}])
        FakeServer.request_analysis([%{"run_id" => 3, "source" => "compiler", "args" => []}])

        refute_result_yet(2, 300)
        refute_result_yet(3, 300)

        {:ok, context}
      end

      then_ "only one fresh run is scheduled, and both requesters share its result", context do
        BlockingProject.unblock(context.marker)

        result_1 = await_result(1)
        result_2 = await_result(2)
        result_3 = await_result(3)

        assert result_1["status"] == "ok"

        assert_same_real_result(result_1, result_2)
        assert_same_real_result(result_1, result_3)

        assert BlockingProject.execution_count(context.project.root) == 2,
               "run 1, plus exactly one coalesced next run serving both ties — " <>
                 "not one execution per duplicate, which would reintroduce the " <>
                 "pile-up tying exists instead of. Got: " <>
                 "#{BlockingProject.execution_count(context.project.root)} executions"

        {:ok, context}
      end
    end
  end
end
