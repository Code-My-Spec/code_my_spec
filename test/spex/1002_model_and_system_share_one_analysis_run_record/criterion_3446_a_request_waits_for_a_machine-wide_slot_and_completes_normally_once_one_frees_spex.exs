defmodule CodeMySpecSpex.Story839.Criterion3446Spex do
  @moduledoc """
  Story 839 — Model and system share one analysis run record.
  Criterion 3446 — A request waits for a machine-wide slot and completes
  normally once one frees.

  Same rule and mechanism as criterion 3440, recorded as its own scenario:
  a request finds no free machine-wide slot, waits, and runs to a normal
  completion once one frees — proving the wait itself does no harm to the
  run, not only that it eventually happens.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects,
    only: [ensure_harness_supervisor_started: 0, project_dir: 0, stop_project: 1]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarness.AnalysisSlots
  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer

  defp occupy_the_only_slot(context) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:took, AnalysisSlots.acquire()})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:took, :ok}, 1_000

    on_exit(fn -> Process.exit(pid, :kill) end)
    {:ok, Map.put(context, :slot_holder, pid)}
  end

  spex "A request waits for a machine-wide slot and completes normally once one frees" do
    scenario "both machine-wide slots are held by other working copies" do
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

      given_ "the machine's only slot is held by another working copy's run", context do
        occupy_the_only_slot(context)
      end

      when_ "a new analyzer request arrives", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "compiler", "args" => []}])
        refute_result_yet(1, 300)

        {:ok, context}
      end

      then_ "once a slot frees it runs and completes cleanly", context do
        send(context.slot_holder, :release)

        result = await_result(1)

        assert result["status"] == "ok"

        assert result["result"]["diagnostics"] == [],
               "the fixture project compiles cleanly; a normal completion " <>
                 "reports no diagnostics. Got: #{inspect(result)}"

        {:ok, context}
      end
    end
  end
end
