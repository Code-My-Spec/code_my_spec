defmodule CodeMySpec.Requirements.ComponentFamilyOwnershipTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.ComponentsFixtures
  alias CodeMySpec.Configurations
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.RequirementGraph

  test "a narrow child recompute keeps the context template's definition metadata" do
    scope = full_scope_fixture()
    umbrella = ComponentsFixtures.component_fixture(scope, %{type: "infrastructure"})

    {:ok, context} =
      Components.create_component(scope, %{
        name: "DevelopContext",
        type: "context",
        module_name: "DevelopContext",
        parent_component_id: umbrella.id
      })

    {:ok, child} =
      Components.create_component(scope, %{
        name: "RetireAgent",
        type: "genserver",
        module_name: "RetireAgent",
        parent_component_id: context.id
      })

    config = Configurations.get_or_create(scope)
    {:ok, full_context} = Preloader.load(scope)
    full_nodes = full_nodes(full_context, scope, config)
    full_child_nodes = Enum.filter(full_nodes, &(&1.entity_id == child.id))

    {:ok, narrow_context} = Preloader.load_component_family(scope, child.id)

    {covered, narrow_child_nodes} =
      RequirementGraph.compute_entity(scope, narrow_context, config, {"component", child.id})

    assert MapSet.member?(covered, {"component", context.id})

    full_metadata = Enum.map(full_child_nodes, &metadata/1) |> Enum.sort()

    narrow_metadata =
      narrow_child_nodes
      |> Enum.filter(&(&1.entity_id == child.id))
      |> Enum.map(&metadata/1)
      |> Enum.sort()

    assert narrow_metadata == full_metadata
    assert Enum.any?(narrow_child_nodes, &(&1.owner_component_type == "context"))

    expected_entities =
      Map.new(full_context.components, &{{"component", &1.id}, MapSet.new()})
      |> Map.merge(Map.new(full_context.stories, &{{"story", &1.id}, MapSet.new()}))
      |> Map.merge(
        full_nodes
        |> Enum.reject(&(&1.entity_type == "project"))
        |> Enum.group_by(&{&1.entity_type, &1.entity_id}, & &1.name)
        |> Map.new(fn {key, names} -> {key, MapSet.new(names)} end)
      )

    assert RequirementGraph.defined_entities(full_context, config) == expected_entities
  end

  defp full_nodes(ctx, scope, config) do
    {nodes, _edges} = RequirementGraph.compute_topology(scope, ctx, config)
    nodes
  end

  defp metadata(node) do
    {node.name, node.owner_component_type, node.orchestrated_by, node.node_scope,
     node.parent_entity_id, node.parent_entity_name}
  end
end
