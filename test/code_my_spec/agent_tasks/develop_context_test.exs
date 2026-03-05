defmodule CodeMySpec.AgentTasks.DevelopContextTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.DevelopContext
  alias CodeMySpec.Components

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  defp create_context_with_children(scope) do
    context =
      component_fixture(scope, %{
        name: "TestContext",
        type: "context",
        module_name: "CodeMySpec.TestContext"
      })

    child1 =
      component_fixture(scope, %{
        name: "TestSchema",
        type: "schema",
        module_name: "CodeMySpec.TestContext.TestSchema",
        parent_component_id: context.id
      })

    child2 =
      component_fixture(scope, %{
        name: "TestRepository",
        type: "repository",
        module_name: "CodeMySpec.TestContext.TestRepository",
        parent_component_id: context.id
      })

    {context, [child1, child2]}
  end

  defp create_session(scope, component) do
    %{component: component, project: scope.active_project}
  end

  describe "command/3" do
    test "returns static development instructions with context name" do
      scope = full_scope_fixture()
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      assert {:ok, prompt} = DevelopContext.command(scope, session)
      assert prompt =~ "Develop Context: TestContext"
      assert prompt =~ "Lifecycle Phases"
      assert prompt =~ "Context Spec"
      assert prompt =~ "Design Review"
      assert prompt =~ "Implementation"
      assert prompt =~ "spec-writer"
      assert prompt =~ "test-writer"
      assert prompt =~ "code-writer"
    end
  end

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all requirements satisfied" do
      scope = full_scope_fixture()
      {context, children} = create_context_with_children(scope)

      for component <- [context | children] do
        for name <- ["spec_file", "spec_valid", "implementation_file", "test_file", "tests_passing"] do
          requirement_fixture(scope, component, %{
            name: name,
            artifact_type: :specification,
            satisfied: true
          })
        end
      end

      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      assert {:ok, :valid} = DevelopContext.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when requirements are unsatisfied" do
      scope = full_scope_fixture()
      {context, children} = create_context_with_children(scope)

      # Give context satisfied reqs, but leave children unsatisfied
      requirement_fixture(scope, context, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true
      })

      for child <- children do
        requirement_fixture(scope, child, %{
          name: "spec_file",
          artifact_type: :specification,
          satisfied: false
        })
      end

      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      assert {:ok, :invalid, feedback} = DevelopContext.evaluate(scope, session)
      assert feedback =~ "Components still need work"
      assert feedback =~ "TestSchema"
      assert feedback =~ "TestRepository"
    end

    test "returns :valid when no tracked requirements exist (vacuously satisfied)" do
      scope = full_scope_fixture()
      {context, _children} = create_context_with_children(scope)

      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      assert {:ok, :valid} = DevelopContext.evaluate(scope, session)
    end
  end
end
