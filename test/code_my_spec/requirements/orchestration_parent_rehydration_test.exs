defmodule CodeMySpec.Requirements.OrchestrationParentRehydrationTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements.{Preloader, Projection, RequirementGraph}

  test "rehydration preserves child and standalone orchestration parents" do
    scope = full_scope_fixture()
    context = component_fixture(scope, %{type: "context", module_name: "Example.Context"})

    {:ok, context_child} =
      Components.create_component(scope, %{
        name: "ContextChild",
        module_name: "Example.Context.ContextChild",
        type: "module",
        parent_component_id: context.id
      })

    structural_parent =
      component_fixture(scope, %{type: "module", module_name: "Example.StructuralParent"})

    {:ok, standalone_child} =
      Components.create_component(scope, %{
        name: "StandaloneChild",
        module_name: "Example.StructuralParent.StandaloneChild",
        type: "module",
        parent_component_id: structural_parent.id
      })

    {computed, _computed_edges} = RequirementGraph.compute_graph(scope)
    _served = CodeMySpec.Requirements.recompute(scope)
    assert {:ok, ctx} = Preloader.load(scope)

    {rehydrated, _edges} =
      Projection.load(scope, ctx)

    compare_parent = fn id, name, node_scope ->
      computed_node =
        Enum.find(computed, fn node ->
          node.entity_id == id and node.name == name and node.node_scope == node_scope
        end)

      loaded_node = Enum.find(rehydrated, &(&1.entity_id == id and &1.name == name))

      assert computed_node
      assert loaded_node

      assert {loaded_node.parent_entity_id, loaded_node.parent_entity_name} ==
               {computed_node.parent_entity_id, computed_node.parent_entity_name}
    end

    # The context's child-scoped implementation requirement is grouped under
    # the context that orchestrates the child's work.
    compare_parent.(context_child.id, "implementation_file", :child)

    # A module's own self-scoped implementation remains unparented even when
    # the module sits structurally inside another module.
    compare_parent.(standalone_child.id, "implementation_file", :self)

    standalone_node =
      Enum.find(
        rehydrated,
        &(&1.entity_id == standalone_child.id and &1.name == "implementation_file")
      )

    assert is_nil(standalone_node.parent_entity_id)
    assert is_nil(standalone_node.parent_entity_name)

    # The context's orchestrated parent-scoped node groups under itself.
    compare_parent.(context.id, "implementation_file", :parent)

    parent_node =
      Enum.find(rehydrated, &(&1.entity_id == context.id and &1.name == "implementation_file"))

    assert parent_node.parent_entity_id == context.id
    assert parent_node.parent_entity_name == context.module_name
  end
end
