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

  # Explicitly sync: `CmsHarness.AnalysisSlots` is a machine-wide semaphore
  # by design (its own moduledoc: coordinating analyzer runs *across* every
  # working copy one harness serves, not per-test state) -- two instances of
  # this file running concurrently are two processes racing for the one real
  # resource the criterion is about, which is correct production behavior
  # and a guaranteed `{:already_started, pid}` collision as a test.
  use CodeMySpecSpex.Case, async: false

  import CmsHarnessTest.Projects,
    only: [
      ensure_harness_supervisor_started: 0,
      project_dir: 0,
      stop_project: 1,
      ensure_started: 1
    ]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarnessTest.BlockingProject
  alias CmsHarnessTest.FakeServer

  # `fail_on_error_logs: false` — a hung analyzer being killed and reported
  # is this scenario's expected outcome, not a defect, and both the kill and
  # the resulting "did not produce a result" are real `Logger.error` calls.
  spex "An analyzer that hangs after acquiring a slot is still killed on its timeout",
    fail_on_error_logs: false,
    criterion: 1386 do
    scenario "a compiler run never finishes once it starts" do
      given_ "a working copy whose compiler analyzer blocks — and here, never unblocks",
             context do
        ensure_harness_supervisor_started()
        project = project_dir()
        BlockingProject.make_blocking(project.root)
        on_exit(fn -> stop_project(project.root) end)

        FakeServer.start()
        {:ok, _pid} = ensure_started(project.root)
        await_connected(project.root)

        {:ok, Map.put(context, :project, project)}
      end

      given_ "a kill timeout derived from this machine's own measured mix-subprocess " <>
               "boot cost, not a guessed constant",
             context do
        # 55379e16: a fixed millisecond budget races per-invocation OS-process +
        # BEAM-boot + Mix-bootstrap latency, confirmed independent of _build
        # cache warmth -- the same cost on a busier machine, any day. Reading
        # make_blocking/1's own unarmed warm-compile timing (just taken, same
        # project, same MIX_BUILD_PATH) answers "how long does spawning mix
        # cost right now" directly, rather than guessing a number that races
        # the exact same cost the next time this machine is busier. 3x
        # margin, floor 300ms: generous enough to clear that cost reliably
        # without waiting anywhere near production's 30-minute default.
        boot_ms = BlockingProject.warm_boot_ms(context.project.root)
        timeout = max(300, boot_ms * 3)
        Application.put_env(:code_my_spec, :harness_analysis_timeout, timeout)
        on_exit(fn -> Application.delete_env(:code_my_spec, :harness_analysis_timeout) end)

        {:ok, context}
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
