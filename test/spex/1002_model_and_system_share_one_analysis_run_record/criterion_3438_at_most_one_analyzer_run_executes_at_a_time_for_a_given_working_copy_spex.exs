defmodule CodeMySpecSpex.Story839.Criterion3438Spex do
  @moduledoc """
  Story 839 — Model and system share one analysis run record.
  Criterion 3438 — At most one analyzer run executes at a time for a given
  working copy.

  Rule: at most one analyzer run executes at a time for a given working
  copy — a request for a different source while one is already running
  queues behind it rather than running concurrently.

  `mix test` and `mix spex` share `_build/test`; two `mix` processes against
  one checkout at once corrupt it into reporting failures that are not in
  the code. This is the guarantee that prevents it, asserted over the real
  wire rather than against `AnalysisServer`'s internal state directly — the
  state already proves the queue *decided* to serialize; this proves the
  second source's analyzer subprocess genuinely never started early.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects,
    only: [ensure_harness_supervisor_started: 0, project_dir: 0, stop_project: 1]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarness.Projects
  alias CmsHarnessTest.BlockingProject
  alias CmsHarnessTest.FakeServer

  # `fail_on_error_logs: false` — the scenario's whole point is that credo
  # genuinely never runs early, and this project's own way of proving that
  # (no credo dependency declared) makes a real, expected
  # `Logger.error("credo is not installed")` when it finally does run.
  spex "A second source queues behind the first rather than running concurrently",
    fail_on_error_logs: false do
    scenario "compiler is running when a credo request arrives" do
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

      given_ "compiler is currently running for that working copy", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "compiler", "args" => []}])
        BlockingProject.await_started(context.project.root)

        {:ok, context}
      end

      when_ "a request for credo on the same working copy arrives", context do
        FakeServer.request_analysis([%{"run_id" => 2, "source" => "credo", "args" => []}])

        {:ok, context}
      end

      then_ "credo has not started — it is queued, not running concurrently", context do
        # No mix project here declares credo as a dependency, so a credo run
        # that actually started would answer almost immediately with "credo
        # is not installed" — fast enough that its absence here is only
        # explained by the queue, not by credo happening to be slow.
        refute_result_yet(2, 300)

        {:ok, context}
      end

      then_ "credo only starts, and finishes, once compiler is unblocked", context do
        BlockingProject.unblock(context.marker)

        compiler_result = await_result(1)
        credo_result = await_result(2)

        assert compiler_result["status"] == "ok"

        assert credo_result["status"] == "error",
               "the premise for 'credo never ran concurrently' requires that it " <>
                 "genuinely never ran until dispatched — this project declares no " <>
                 "credo dependency, so a real credo run fails this way. Got: " <>
                 inspect(credo_result)

        assert credo_result["error"] =~ "credo is not installed"

        {:ok, context}
      end
    end
  end
end
