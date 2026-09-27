defmodule CodeMySpec.McpServers.Tasks.Tools.StartAnalysisTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.McpServers.Tasks.Tools.StartAnalysis

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  test "returns a persisted run id before the harness has executed anything", %{
    scope: scope,
    frame: frame
  } do
    assert :ok = HarnessRegistry.register_executor(scope.active_working_copy_id)

    assert {:reply, response, ^frame} = StartAnalysis.execute(%{source: "compiler"}, frame)
    refute response.isError
    assert_receive {:run_analysis, [%{"run_id" => run_id, "source" => "compiler", "args" => []}]}
    assert text(response) =~ "Run #{run_id}"
    run = RunsRepository.get_run_in_project(scope, run_id)
    assert run.status == :running
    assert run.requested_by["tool"] == "start_analysis"
  end

  test "refuses a disconnected checkout when the web app has no local executor", %{
    scope: scope,
    frame: frame
  } do
    # The web app runs `:async` and has no `ServerSupervisor`; both halves are
    # needed to be it. Under the test env's `:inline` a run executes in-process,
    # which is always available, so removing the supervisor alone models nothing.
    previous = Application.get_env(:code_my_spec, :analysis_mode)
    Application.put_env(:code_my_spec, :analysis_mode, :async)
    on_exit(fn -> Application.put_env(:code_my_spec, :analysis_mode, previous) end)

    :ok = Supervisor.terminate_child(Analysis.Supervisor, Analysis.ServerSupervisor)
    on_exit(fn -> Supervisor.restart_child(Analysis.Supervisor, Analysis.ServerSupervisor) end)
    assert Process.whereis(Analysis.ServerSupervisor) == nil
    assert {:reply, response, ^frame} = StartAnalysis.execute(%{source: "compiler"}, frame)
    assert response.isError
    assert text(response) =~ "no harness is connected"
    assert RunsRepository.latest_full_runs(scope) == %{}
  end

  test "an invalid source returns an error without opening a run", %{scope: scope, frame: frame} do
    assert {:reply, response, ^frame} = StartAnalysis.execute(%{source: "unknown"}, frame)
    assert response.isError
    assert RunsRepository.latest_full_runs(scope) == %{}
  end

  test "database read exceptions are returned to the caller", %{scope: scope, frame: frame} do
    invalid_scope = %{scope | active_working_copy_id: "not-a-uuid"}
    frame = %{frame | assigns: %{current_scope: invalid_scope}}

    assert {:reply, response, ^frame} = StartAnalysis.execute(%{source: "compiler"}, frame)
    assert response.isError
    assert text(response) =~ "Could not admit compiler"
    assert RunsRepository.latest_full_runs(scope) == %{}
  end

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end
end
