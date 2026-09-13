defmodule CodeMySpecSpex.Story839.Criterion3447Spex do
  @moduledoc """
  Story 839 — Model and system share one analysis run record.
  Criterion 3447 — An analyzer that hangs after acquiring a slot is still
  killed on its timeout.

  The kill timer moved to arm on `:slot_acquired` rather than at dispatch
  (criterion 3440), so this is the check that the move did not quietly lose
  the timer altogether: an analyzer that never returns must still be killed,
  counted from when it actually started rather than never at all.

  The blocking compiler fixture is used unblocked on purpose — a hang that
  never receives the signal to proceed *is* the failure mode this criterion
  is about, not a test bug.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects,
    only: [ensure_harness_supervisor_started: 0, project_dir: 0, stop_project: 1]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarness.Projects
  alias CmsHarnessTest.BlockingProject
  alias CmsHarnessTest.FakeServer

  # `fail_on_error_logs: false` — a hung analyzer being killed and reported
  # is this scenario's expected outcome, not a defect, and both the kill and
  # the resulting "did not produce a result" are real `Logger.error` calls.
  spex "An analyzer that hangs after acquiring a slot is still killed on its timeout",
    fail_on_error_logs: false do
    scenario "a compiler run never finishes once it starts" do
      given_ "a short kill timeout, so this scenario does not wait thirty minutes", context do
        Application.put_env(:code_my_spec, :harness_analysis_timeout, 300)
        on_exit(fn -> Application.delete_env(:code_my_spec, :harness_analysis_timeout) end)

        {:ok, context}
      end

      given_ "a working copy whose compiler analyzer blocks — and here, never unblocks",
             context do
        ensure_harness_supervisor_started()
        project = project_dir()
        BlockingProject.make_blocking(project.root)
        on_exit(fn -> stop_project(project.root) end)

        FakeServer.start()
        {:ok, _pid} = Projects.ensure_started(project.root)
        await_connected(project.root)

        {:ok, Map.put(context, :project, project)}
      end

      when_ "the harness is asked to run it", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "compiler", "args" => []}])
        BlockingProject.await_started(context.project.root)

        {:ok, context}
      end

      then_ "it is still killed on its timeout, counted from when it actually started",
            context do
        result = await_result(1, 5_000)

        assert result["status"] == "error",
               "a hung analyzer must be answered, not left silent forever. " <>
                 "Got: #{inspect(result)}"

        assert result["error"] =~ "timed out",
               "the answer has to say it was a timeout, not some other " <>
                 "failure, so the next stop re-enqueues rather than treating " <>
                 "this as a real diagnostic. Got: #{inspect(result)}"

        {:ok, context}
      end
    end
  end
end
