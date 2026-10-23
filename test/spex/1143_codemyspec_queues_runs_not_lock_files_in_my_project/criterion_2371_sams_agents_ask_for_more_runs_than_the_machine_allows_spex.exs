defmodule CodeMySpecSpex.Story1143.Criterion2371Spex do
  @moduledoc """
  Story 1143 — CodeMySpec queues runs, not lock files in my project.
  Criterion 2371 — Sam's agents ask for more runs than the machine allows.

  The machine's limit is CodeMySpec's: two runs hold both slots, and a third
  request waits in the harness until one frees, then runs.
  """

  # `CmsHarness.AnalysisSlots` is one machine-wide semaphore; two copies of
  # this file at once would race for the resource the criterion is about.
  use CodeMySpecSpex.Case, async: false

  import CmsHarnessTest.Projects,
    only: [
      ensure_harness_supervisor_started: 0,
      project_dir: 0,
      stop_project: 1,
      ensure_started: 1
    ]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarnessTest.FakeServer
  alias CmsHarnessTest.SlotHolder

  spex "Sam's agents ask for more runs than the machine allows", criterion: 2371 do
    scenario "a third run waits for one of two running runs to finish" do
      given_ "Sam's machine allows two runs at once", context do
        Application.put_env(:code_my_spec, :analysis_slots, 2)
        on_exit(fn -> Application.delete_env(:code_my_spec, :analysis_slots) end)

        {:ok, context}
      end

      given_ "Sam's working copy is connected to the harness", context do
        ensure_harness_supervisor_started()
        project = project_dir()
        on_exit(fn -> stop_project(project.root) end)

        FakeServer.start()
        {:ok, _pid} = ensure_started(project.root)
        await_connected(project.root)

        {:ok, Map.put(context, :project, project)}
      end

      given_ "two runs are already running on the machine", context do
        {:ok, Map.put(context, :running, [SlotHolder.occupy(), SlotHolder.occupy()])}
      end

      when_ "a third run is requested", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "compiler", "args" => []}])

        {:ok, context}
      end

      then_ "the third waits while both are running", context do
        refute_result_yet(1, 300)

        {:ok, context}
      end

      then_ "and runs once one of them finishes", context do
        context.running |> hd() |> SlotHolder.release()

        assert await_result(1)["status"] == "ok"

        {:ok, context}
      end
    end
  end
end
