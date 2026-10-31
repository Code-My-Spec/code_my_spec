defmodule CodeMySpecSpex.Story1142.Criterion2370Spex do
  @moduledoc """
  Story 1142 — A test run survives its harness and is answered once.
  Criterion 2370 — Sam's run on Windows is adopted after a harness restart.

  Adoption is cluster messaging, the same on every platform: nothing in it
  depends on `CodeMySpec.RunGuard`, which does not start on Windows, or on
  Unix process groups. What differs on Windows is only the launch: `mix.bat`
  goes through `cmd.exe /d /c call`, with `:hide`, and no shell redirect,
  since the run writes its own output. That launch is asserted here as far as
  macOS can; the run itself on Windows is proven on a Windows machine.
  """

  # One harness tree and one machine-wide slot table per node.
  use CodeMySpecSpex.Case, async: false

  import CmsHarnessTest.Projects,
    only: [
      ensure_harness_supervisor_started: 0,
      project_dir: 0,
      stop_project: 1,
      ensure_started: 1
    ]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarnessTest.ClusteredProject
  alias CmsHarnessTest.FakeServer

  alias CodeMySpec.ExecutionContexts.Local

  spex "Sam's run on Windows is adopted after a harness restart", criterion: 2370 do
    scenario "the harness restarts on a machine without Unix process groups" do
      given_ "Sam works on Windows", context do
        ensure_harness_supervisor_started()
        :ok = ClusteredProject.as_on_windows()
        {:ok, context}
      end

      given_ "Sam's working copy is served by his harness", context do
        ensure_harness_supervisor_started()
        project = project_dir()
        :ok = ClusteredProject.make(project.root)
        on_exit(fn -> stop_project(project.root) end)

        FakeServer.start()
        {:ok, _pid} = ensure_started(project.root)
        await_connected(project.root)

        {:ok, Map.put(context, :project, project)}
      end

      given_ "Sam's suite is running for his harness", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "exunit", "args" => []}])
        {:ok, Map.put(context, :os_pid, ClusteredProject.await_running(context.project.root))}
      end

      when_ "his harness restarts", context do
        restart_harness(context.project.root)
        {:ok, context}
      end

      then_ "the run is adopted and answered once, as on macOS or Linux", context do
        assert ClusteredProject.running?(context.os_pid)
        :ok = ClusteredProject.release(context.project.root)

        assert %{"status" => "ok"} = await_result(1)
        :ok = refute_result_yet(1, 2_000)
        {:ok, context}
      end
    end

    scenario "Sam's mix is a Windows batch launcher" do
      given_ "mix on Sam's machine is mix.bat", context do
        {:ok, Map.put(context, :mix, "C:\\tools\\elixir\\bin\\mix.bat")}
      end

      when_ "the harness works out how to launch his run", context do
        {:ok, Map.put(context, :launch, Local.launch(context.mix, ["test"]))}
      end

      then_ "it goes through cmd.exe, with no shell redirect, and hidden", context do
        {program, argv, spawn_opts} = context.launch

        assert Path.basename(program) == "cmd.exe"
        assert argv == ["/d", "/c", "call", context.mix, "test"]
        assert :hide in spawn_opts
        refute Enum.any?(argv, &String.contains?(&1, ">")), "the run writes its own output"
        {:ok, context}
      end
    end
  end

  # What a harness restart does to it: its copy's queue and the node's run
  # link go, and come back empty. The link through its supervisor, not killed:
  # a kill spends the restart budget every harness child shares.
  defp restart_harness(root) do
    stop_project(root)
    :ok = Supervisor.terminate_child(CmsHarness.Supervisor, CmsHarness.RunLink)
    {:ok, _pid} = Supervisor.restart_child(CmsHarness.Supervisor, CmsHarness.RunLink)
    {:ok, _pid} = ensure_started(root)
    await_connected(root)
  end
end
