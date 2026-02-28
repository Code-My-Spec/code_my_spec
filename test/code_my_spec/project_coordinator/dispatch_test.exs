defmodule CodeMySpec.ProjectCoordinator.DispatchTest do
  use CodeMySpec.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProjectCoordinator.Dispatch
  alias CodeMySpec.Requirements.Requirement

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  # ============================================================================
  # command/3 with :local scope
  # ============================================================================

  describe "command/3 with :local scope" do
    test "dispatches to task module's command/3", %{scope: scope} do
      context = component_fixture(scope, %{name: "Blog", module_name: "Blog", type: "context"})

      req = %Requirement{
        scope: :local,
        component_id: context.id,
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs
      }

      assert {:ok, prompt} = Dispatch.command(req, scope, %{})
      assert prompt =~ "Blog"
    end
  end

  # ============================================================================
  # command/3 with :children scope
  # ============================================================================

  describe "command/3 with :children scope" do
    test "returns parent prompt plus orchestration for actionable children", %{scope: scope} do
      context = component_fixture(scope, %{name: "Blog", module_name: "Blog", type: "context"})

      _child =
        component_fixture(scope, %{
          name: "Post",
          module_name: "Blog.Post",
          type: "schema",
          parent_component_id: context.id
        })

      req = %Requirement{
        scope: :children,
        component_id: context.id,
        name: "children_designs",
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs
      }

      assert {:ok, prompt} = Dispatch.command(req, scope, %{})
      # Contains parent prompt
      assert prompt =~ "Child Component Designs"
      # Contains orchestration section
      assert prompt =~ "Development: Blog"
    end

    test "context with no children still finds actionable work on context itself", %{
      scope: scope
    } do
      # collect_components includes the context itself for container types,
      # so even without children the context has its own unsatisfied requirements
      context = component_fixture(scope, %{name: "Empty", module_name: "Empty", type: "context"})

      req = %Requirement{
        scope: :children,
        component_id: context.id,
        name: "children_designs",
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs
      }

      assert {:ok, prompt} = Dispatch.command(req, scope, %{})
      assert prompt =~ "Empty"
    end
  end

  # ============================================================================
  # evaluate/3
  # ============================================================================

  describe "evaluate/3 with :children scope" do
    test "returns :invalid when children have actionable work", %{scope: scope} do
      context = component_fixture(scope, %{name: "Blog", module_name: "Blog", type: "context"})

      _child =
        component_fixture(scope, %{
          name: "Post",
          module_name: "Blog.Post",
          type: "schema",
          parent_component_id: context.id
        })

      req = %Requirement{
        scope: :children,
        component_id: context.id,
        name: "children_designs",
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs
      }

      # Children have unsatisfied requirements → invalid with feedback
      assert {:ok, :invalid, feedback} = Dispatch.evaluate(req, scope, %{})
      assert is_binary(feedback)
    end

    test "returns :valid when all children are satisfied", %{scope: scope} do
      context = component_fixture(scope, %{name: "Done", module_name: "Done", type: "context"})

      child =
        component_fixture(scope, %{
          name: "Item",
          module_name: "Done.Item",
          type: "schema",
          parent_component_id: context.id
        })

      # Satisfy all schema requirements
      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification},
            {"implementation_file", :code}
          ] do
        {:ok, _} =
          CodeMySpec.Requirements.create_requirement(scope, child, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      req = %Requirement{
        scope: :children,
        component_id: context.id,
        name: "children_designs",
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs
      }

      assert {:ok, :valid} = Dispatch.evaluate(req, scope, %{})
    end
  end

  describe "evaluate/3 with :local scope" do
    test "delegates to task module's evaluate/3", %{scope: scope} do
      context = component_fixture(scope, %{name: "Blog", module_name: "Blog", type: "context"})

      _child =
        component_fixture(scope, %{
          name: "Post",
          module_name: "Blog.Post",
          type: "schema",
          parent_component_id: context.id
        })

      req = %Requirement{
        scope: :local,
        component_id: context.id,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec
      }

      result = Dispatch.evaluate(req, scope, %{})

      case result do
        {:ok, :valid} -> :ok
        {:ok, :invalid, _feedback} -> :ok
      end
    end
  end
end
