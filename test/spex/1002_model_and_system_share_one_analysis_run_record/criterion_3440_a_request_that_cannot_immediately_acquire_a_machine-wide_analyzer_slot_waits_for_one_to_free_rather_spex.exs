defmodule CodeMySpecSpex.Story839.Criterion3440Spex do
  @moduledoc """
  Story 839 — Model and system share one analysis run record.
  Criterion 3440 — A request that cannot immediately acquire a machine-wide
  analyzer slot waits for one to free rather than being refused outright,
  and the wait does not consume the run's kill-timer budget.

  Superseded, until tonight: `AnalysisSlots.acquire/0` answered `:busy` at
  once, because `AnalysisServer` armed its kill timer at dispatch — a run
  that waited its turn would spend that budget waiting and then be killed
  for being slow, misattributed as a hung tool. The timer moved to arm only
  once the analyzer actually starts (`:slot_acquired`), so waiting for a
  slot no longer costs it.

  The slot is occupied directly — the same way `analysis_slots_test.exs`
  does — rather than by running a second real harness against it, because
  `CmsHarnessTest.FakeServer` is a singleton per test process and cannot
  address two connected harnesses independently. What matters here is
  `AnalysisSlots` genuinely being at its limit when the harness's own
  dispatched run reaches it, and that is true either way.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects,
    only: [ensure_harness_supervisor_started: 0, project_dir: 0, stop_project: 1]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer
  alias CmsHarnessTest.SlotHolder

  spex "A request that cannot immediately get a machine-wide slot waits for one" do
    scenario "the machine's one slot is already held when a run is dispatched" do
      given_ "this machine allows only one analyzer slot", context do
        Application.put_env(:code_my_spec, :analysis_slots, 1)
        on_exit(fn -> Application.delete_env(:code_my_spec, :analysis_slots) end)

        {:ok, context}
      end

      given_ "a working copy connected and ready to run an analyzer", context do
        ensure_harness_supervisor_started()
        project = project_dir()
        on_exit(fn -> stop_project(project.root) end)

        FakeServer.start()
        {:ok, _pid} = Projects.ensure_started(project.root)
        await_connected(project.root)

        {:ok, Map.put(context, :project, project)}
      end

      given_ "the machine's one slot is already held by something else", context do
        {:ok, Map.put(context, :slot_holder, SlotHolder.occupy())}
      end

      when_ "the harness is asked to run an analyzer", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "compiler", "args" => []}])

        {:ok, context}
      end

      then_ "the request waits rather than being refused at once", context do
        refute_result_yet(1, 300)

        {:ok, context}
      end

      then_ "it runs and completes once the slot frees", context do
        SlotHolder.release(context.slot_holder)

        result = await_result(1)

        assert result["status"] == "ok",
               "the premise for 'waited rather than refused' requires it to " <>
                 "actually run once the slot freed, not merely to have not " <>
                 "answered yet. Got: #{inspect(result)}"

        {:ok, context}
      end
    end
  end
end
