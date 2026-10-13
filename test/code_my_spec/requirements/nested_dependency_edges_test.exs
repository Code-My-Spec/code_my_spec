defmodule CodeMySpec.Requirements.NestedDependencyEdgesTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Requirements.RequirementGraph

  test "a child's external dependency connects through the child to its context" do
    faults = component("faults", "module")
    requirements = component("requirements", "context")
    watcher = component("watcher", "module", requirements.id, [faults])
    edges = edges([faults, requirements, watcher])

    assert edge(faults, watcher) in edges
    assert edge(watcher, requirements) in edges
  end

  test "a context nested under infrastructure retains its declared dependencies" do
    namespace = component("namespace", "infrastructure")
    faults = component("faults", "module", namespace.id)
    requirements = component("requirements", "context", namespace.id, [faults])
    watcher = component("watcher", "module", requirements.id)
    edges = edges([namespace, faults, requirements, watcher])

    # Through the context's junction: the dependency gates it once, and it
    # gates each child.
    assert %{from: key(faults), to: junction(requirements)} in edges
    assert %{from: junction(requirements), to: key(watcher)} in edges
    assert edge(watcher, requirements) in edges
  end

  defp edges(components) do
    ctx = %{
      components: components,
      components_by_id: Map.new(components, &{&1.id, &1}),
      children_by_parent: Enum.group_by(components, & &1.parent_component_id)
    }

    RequirementGraph.component_side_edges(ctx, %ProjectConfiguration{})
  end

  defp component(id, type, parent \\ nil, dependencies \\ []) do
    %Component{
      id: id,
      module_name: id,
      type: type,
      parent_component_id: parent,
      dependencies: dependencies
    }
  end

  defp key(component), do: {"component", component.id, "implementation_file"}
  defp junction(component), do: {"component", component.id, "dependencies_met"}
  defp edge(from, to), do: %{from: key(from), to: key(to)}
end
