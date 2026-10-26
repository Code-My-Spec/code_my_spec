defmodule CodeMySpec.Requirements.AProjectorThatDiedIsRestartedByTheNextReadTest do
  @moduledoc """
  A projector that dies without being stopped is restarted by the next read.
  `:4000` recompiling under it after a landing killed it, its supervisor's
  restarts failed the same way and it gave up, and for twenty minutes every
  read settled against nothing: 1148's triage requirement read "1 untriaged"
  through 44 offers (issue 2c76a860). One that was stopped stays stopped.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo.SandboxAllowance
  alias CodeMySpec.Requirements.{IncrementalGraph, RequirementGraph}

  setup do
    scope = full_scope_fixture()
    {:ok, pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)
    stop(pid)

    on_exit(fn ->
      CodeMySpec.Requirements.Registry
      |> Registry.lookup({scope.active_project_id, :graph})
      |> stop_registered()
    end)

    %{scope: scope}
  end

  defp stop_registered([{pid, _}]), do: stop(pid)
  defp stop_registered([]), do: :ok

  defp stop(pid),
    do: DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)

  test "one that died under no supervisor's care is running again after a read", %{scope: scope} do
    project_id = scope.active_project_id

    # Outside the supervisor, so nothing restarts it: the supervisor that gave up.
    {:ok, pid} =
      GenServer.start(IncrementalGraph, {project_id, scope, SandboxAllowance.owners()},
        name: IncrementalGraph.via(project_id)
      )

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert IncrementalGraph.orphaned?(project_id)

    :ok = RequirementGraph.settle(scope)

    assert IncrementalGraph.running?(project_id)
    refute IncrementalGraph.orphaned?(project_id)
  end

  test "one that was stopped is not started by a read", %{scope: scope} do
    refute IncrementalGraph.orphaned?(scope.active_project_id)

    :ok = RequirementGraph.settle(scope)

    refute IncrementalGraph.running?(scope.active_project_id)
  end
end
