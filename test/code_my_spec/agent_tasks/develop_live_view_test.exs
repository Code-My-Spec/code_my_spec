defmodule CodeMySpec.AgentTasks.DevelopLiveViewTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.DevelopLiveView
  alias CodeMySpec.Components

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  defp create_liveview_with_children(scope) do
    liveview =
      component_fixture(scope, %{
        name: "DashboardLive",
        type: "liveview",
        module_name: "TestAppWeb.DashboardLive"
      })

    child1 =
      component_fixture(scope, %{
        name: "StatsCard",
        type: "liveview_component",
        module_name: "TestAppWeb.DashboardLive.StatsCard",
        parent_component_id: liveview.id
      })

    child2 =
      component_fixture(scope, %{
        name: "ChartWidget",
        type: "liveview_component",
        module_name: "TestAppWeb.DashboardLive.ChartWidget",
        parent_component_id: liveview.id
      })

    {liveview, [child1, child2]}
  end

  defp create_task(scope, component) do
    %{component_id: component.id, project_id: scope.active_project.id, story_id: nil}
  end

  describe "command/3" do
    test "returns static development instructions with LiveView name" do
      scope = full_scope_fixture()
      {liveview, _children} = create_liveview_with_children(scope)
      task = create_task(scope, liveview)

      assert {:ok, prompt} = DevelopLiveView.command(scope, task)
      assert prompt =~ "Develop LiveView: DashboardLive"
      assert prompt =~ "LiveView Spec"
      assert prompt =~ "Component Specs"
      assert prompt =~ "Implementation"
      assert prompt =~ "children first, parent last"
    end
  end

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all components have requirements satisfied" do
      scope = full_scope_fixture()
      {liveview, children} = create_liveview_with_children(scope)

      for component <- [liveview | children] do
        for name <- ["spec_file", "spec_valid", "implementation_file", "test_file", "tests_passing"] do
          requirement_fixture(scope, component, %{
            name: name,
            artifact_type: :specification,
            satisfied: true
          })
        end
      end

      liveview = Components.get_component(scope, liveview.id)
      task = create_task(scope, liveview)

      assert {:ok, :valid} = DevelopLiveView.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when components have unsatisfied requirements" do
      scope = full_scope_fixture()
      {liveview, children} = create_liveview_with_children(scope)

      for component <- [liveview | children] do
        requirement_fixture(scope, component, %{
          name: "spec_file",
          artifact_type: :specification,
          satisfied: false
        })
      end

      liveview = Components.get_component(scope, liveview.id)
      task = create_task(scope, liveview)

      assert {:ok, :invalid, feedback} = DevelopLiveView.evaluate(scope, task)
      assert feedback =~ "Components still need work"
    end

    test "returns :valid when no tracked requirements exist (vacuously satisfied)" do
      scope = full_scope_fixture()
      {liveview, _children} = create_liveview_with_children(scope)

      liveview = Components.get_component(scope, liveview.id)
      task = create_task(scope, liveview)

      assert {:ok, :valid} = DevelopLiveView.evaluate(scope, task)
    end
  end
end
