defmodule CodeMySpec.Requirements.EventOnlyLifecycleTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{DevState, Repo, Requirements}

  alias CodeMySpec.Requirements.{
    GraphInputs,
    GraphWatcher,
    RequirementGraph,
    ShadowProjector,
    Verification
  }

  setup do
    previous =
      for key <- [:graph_pass_enabled, :graph_shadow_projection, :graph_event_is_source],
          into: %{},
          do: {key, Application.get_env(:code_my_spec, key)}

    Application.put_env(:code_my_spec, :graph_pass_enabled, false)
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    Application.put_env(:code_my_spec, :graph_event_is_source, true)
    scope = full_scope_fixture()

    on_exit(fn ->
      for key <- [scope.active_project_id, {scope.active_project_id, :shadow}],
          {pid, _} <- Registry.lookup(CodeMySpec.Requirements.Registry, key) do
        DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)
      end

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:code_my_spec, key)
        {key, value} -> Application.put_env(:code_my_spec, key, value)
      end)
    end)

    %{scope: scope}
  end

  test "normal startup maintains and diagnoses only the serving event writer", %{scope: scope} do
    assert {:ok, projector} = GraphWatcher.ensure_watching(scope)
    assert is_pid(projector)
    assert :ok = ShadowProjector.settle(scope.active_project_id)
    assert_event_only(scope)

    [project] = DevState.report(scope.active_project_id).projects
    assert project.graph_source == "event"
    refute project.graph_pass_enabled
    assert project.graph_writer.active
    assert project.graph_writer.last_error == nil
    refute project.graph_watcher.watching
    assert project.graph_projector.watching
  end

  test "a first read seeds the graph without a legacy watcher", %{scope: scope} do
    refute RequirementGraph.projected?(scope)
    {nodes, _} = Requirements.cached_all(scope)
    assert nodes != []
    assert_event_only(scope)
    assert Verification.clean?(RequirementGraph.served_vs_recomputed(scope))
  end

  test "event updates serve new work and announce it without a pass", %{scope: scope} do
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
    :ok = ShadowProjector.settle(scope.active_project_id, [scope.active_working_copy_id])
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

    # The oracle is still callable without starting its continuous worker.
    assert {{pass_nodes, _edges}, _actionable, _at} = Requirements.recompute(scope)
    assert pass_nodes != []
    assert GraphWatcher.status(scope.active_project_id) == nil
    assert Verification.clean?(RequirementGraph.served_vs_recomputed(scope))
  end

  test "rolling back to pass serving restores its normal startup", %{scope: scope} do
    Application.put_env(:code_my_spec, :graph_event_is_source, false)
    assert GraphWatcher.pass_enabled?()
    assert {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    assert :ok = GraphWatcher.settle(scope)
    assert GraphWatcher.status(scope.active_project_id) != nil
    {nodes, _} = Requirements.cached_all(scope)
    assert nodes != []
  end

  def graph_changed(_event, _measurements, %{scope: scope}, recipient),
    do: send(recipient, {:graph_wake, scope.active_project_id})

  defp assert_event_only(scope) do
    assert ShadowProjector.running?(scope.active_project_id)
    assert GraphWatcher.status(scope.active_project_id) == nil

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM shadow_requirements WHERE project_id = $1",
               [Ecto.UUID.dump!(scope.active_project_id)]
             )
  end
end
