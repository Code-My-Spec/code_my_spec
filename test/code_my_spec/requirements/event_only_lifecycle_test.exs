defmodule CodeMySpec.Requirements.EventOnlyLifecycleTest do
  @moduledoc "The projector keeps the graph: started, seeded, maintained and rebuilt."
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{DevState, Requirements}

  alias CodeMySpec.Requirements.{
    GraphInputs,
    GraphWatcher,
    IncrementalGraph,
    RequirementGraph,
    Verification
  }

  setup do
    scope = full_scope_fixture()

    on_exit(fn ->
      for {pid, _} <-
            Registry.lookup(CodeMySpec.Requirements.Registry, {scope.active_project_id, :graph}) do
        DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)
      end
    end)

    %{scope: scope}
  end

  test "startup starts the projector, and the diagnostics report it", %{scope: scope} do
    assert {:ok, projector} = GraphWatcher.ensure_watching(scope)
    assert is_pid(projector)
    assert :ok = IncrementalGraph.settle(scope.active_project_id)
    assert IncrementalGraph.running?(scope.active_project_id)

    [project] = DevState.report(scope.active_project_id).projects
    assert project.graph_writer.active
    assert project.graph_writer.last_error == nil
    assert project.graph_projector.watching
  end

  test "a first read seeds the graph", %{scope: scope} do
    refute RequirementGraph.projected?(scope)
    {nodes, _} = Requirements.cached_all(scope)
    assert nodes != []
    assert_event_only(scope)
    assert Verification.clean?(RequirementGraph.served_vs_recomputed(scope))
  end

  test "event updates serve new work and announce it", %{scope: scope} do
    {_nodes, _} = Requirements.cached_all(scope)
    GraphInputs.subscribe(scope.active_project_id)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:code_my_spec, :requirements, :graph_changed],
        &__MODULE__.graph_changed/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    story = story_fixture(scope, %{ready_for_dev: true})
    :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])
    {nodes, _} = Requirements.cached_all(scope)

    assert Enum.any?(
             nodes,
             &(&1.entity_type == "story" and to_string(&1.entity_id) == to_string(story.id))
           )

    project_id = scope.active_project_id
    assert_receive {:graph_updated, ^project_id}
    assert_receive {:graph_wake, ^project_id}
    assert_event_only(scope)
    assert Verification.clean?(RequirementGraph.served_vs_recomputed(scope))

    # Recomputing rebuilds the checkout from the domain and serves the same answer.
    assert {{rebuilt, _edges}, _actionable, _at} = Requirements.recompute(scope)
    assert rebuilt != []
    assert Verification.clean?(RequirementGraph.served_vs_recomputed(scope))
  end

  def graph_changed(_event, _measurements, %{scope: scope}, recipient),
    do: send(recipient, {:graph_wake, scope.active_project_id})

  defp assert_event_only(scope),
    do: assert(IncrementalGraph.running?(scope.active_project_id))
end
