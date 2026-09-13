defmodule CodeMySpecSpex.Story839.Criterion3439Spex do
  @moduledoc """
  Story 839 — Model and system share one analysis run record.
  Criterion 3439 — A request for a source that is already running is tied to
  the *next* run for that source, not the one already in flight.

  Rule: a request for a source that is already running is tied to the next
  run for that source, not the one in flight, because the in-flight run may
  be answering input that is now stale relative to what prompted the new
  request.

  Superseded, until tonight: `accept/2` answered a duplicate for a running
  source with a synthetic `{:superseded, "already queued"}` status carrying
  no data — measured on Broken Oaths 2026-09-08 at 397 superseded runs
  against 25 completed in ninety minutes. John: "We can't be superseding
  runs like that. We have to let it finish."

  Driven over the real wire `CmsHarness.Project.AnalysisServer` actually
  answers on — a real websocket, a real `mix compile`, no stubs — because a
  test that called `handle_cast/2` directly would prove the queue's own state
  transition and nothing about whether the harness ever tells the truth
  about it on the channel a real server reads. The compiler analyzer is
  deliberately made to block on a marker file rather than finish in whatever
  the real compile happens to take, so "the first is still running" is a
  fact the scenario controls, not a race against a timer.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects,
    only: [ensure_harness_supervisor_started: 0, project_dir: 0, stop_project: 1]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarness.Projects
  alias CmsHarnessTest.BlockingProject
  alias CmsHarnessTest.FakeServer

  spex "A duplicate request for a running source is tied to the next run" do
    scenario "a second compiler request arrives while the first is still executing" do
      given_ "a working copy whose compiler analyzer blocks until told to proceed", context do
        ensure_harness_supervisor_started()
        project = project_dir()
        marker = BlockingProject.make_blocking(project.root)
        on_exit(fn -> stop_project(project.root) end)

        {:ok, Map.merge(context, %{project: project, marker: marker})}
      end

      given_ "the harness is connected and joined for that working copy", context do
        FakeServer.start()
        {:ok, _pid} = Projects.ensure_started(context.project.root)
        await_connected(context.project.root)

        {:ok, context}
      end

      given_ "a compiler run is already in flight for it", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "compiler", "args" => []}])
        BlockingProject.await_started(context.project.root)

        refute_result_yet(1)

        {:ok, context}
      end

      when_ "a second request for the same source arrives", context do
        FakeServer.request_analysis([%{"run_id" => 2, "source" => "compiler", "args" => []}])

        # Nothing should answer yet — both requests are waiting on the same
        # blocked compile, and unblocking is the next, separate step.
        refute_result_yet(1)
        refute_result_yet(2)

        {:ok, context}
      end

      then_ "letting the first run finish answers both requests with the same real result",
            context do
        BlockingProject.unblock(context.marker)

        result_1 = await_result(1)
        result_2 = await_result(2)

        assert result_1["status"] == "ok",
               "the premise failed: the run itself did not succeed. Got: #{inspect(result_1)}"

        assert Map.delete(result_2, "run_id") == Map.delete(result_1, "run_id"),
               "the tied request has to receive the exact same real result the " <>
                 "primary one does (run_id aside — each request keeps its own) " <>
                 "— never a synthetic status carrying no data. Got: #{inspect(result_2)}"

        {:ok, context}
      end
    end
  end
end
