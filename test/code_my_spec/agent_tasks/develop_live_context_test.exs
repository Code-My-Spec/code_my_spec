defmodule CodeMySpec.AgentTasks.DevelopLiveContextTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.DevelopLiveContext
  alias CodeMySpec.Components

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  defp create_live_context_with_children(scope) do
    live_context =
      component_fixture(scope, %{
        name: "DashboardLive",
        type: "live_context",
        module_name: "TestAppWeb.DashboardLive"
      })

    child1 =
      component_fixture(scope, %{
        name: "StatsView",
        type: "liveview",
        module_name: "TestAppWeb.DashboardLive.StatsView",
        parent_component_id: live_context.id
      })

    child2 =
      component_fixture(scope, %{
        name: "ChartComponent",
        type: "liveview_component",
        module_name: "TestAppWeb.DashboardLive.ChartComponent",
        parent_component_id: live_context.id
      })

    {live_context, [child1, child2]}
  end

  defp create_session(scope, component) do
    %{component: component, project: scope.active_project}
  end

  describe "command/3" do
    test "returns static development instructions with live context name" do
      scope = full_scope_fixture()
      {live_context, _children} = create_live_context_with_children(scope)
      session = create_session(scope, live_context)

      assert {:ok, prompt} = DevelopLiveContext.command(scope, session)
      assert prompt =~ "Develop Live Context: DashboardLive"
      assert prompt =~ "Live Context Spec"
      assert prompt =~ "Child Specs"
      assert prompt =~ "Implementation"
      assert prompt =~ "no code file"
    end
  end

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all children have requirements satisfied" do
      scope = full_scope_fixture()
      {live_context, children} = create_live_context_with_children(scope)

      # Only children need requirements — live_context has no code
      for child <- children do
        for name <- ["spec_file", "spec_valid", "implementation_file", "test_file", "tests_passing"] do
          requirement_fixture(scope, child, %{
            name: name,
            artifact_type: :specification,
            satisfied: true
          })
        end
      end

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, :valid} = DevelopLiveContext.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when children have unsatisfied requirements" do
      scope = full_scope_fixture()
      {live_context, children} = create_live_context_with_children(scope)

      for child <- children do
        requirement_fixture(scope, child, %{
          name: "spec_file",
          artifact_type: :specification,
          satisfied: false
        })
      end

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, :invalid, feedback} = DevelopLiveContext.evaluate(scope, session)
      assert feedback =~ "Children still need work"
      assert feedback =~ "StatsView"
      assert feedback =~ "ChartComponent"
    end

    test "returns :valid when no children have tracked requirements (vacuously satisfied)" do
      scope = full_scope_fixture()
      {live_context, _children} = create_live_context_with_children(scope)

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, :valid} = DevelopLiveContext.evaluate(scope, session)
    end
  end
end
