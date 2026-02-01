defmodule CodeMySpecWeb.ProjectCoordinatorJSON do
  alias CodeMySpec.Components.Component

  def sync_requirements(%{components: components, next_components: next_components}) do
    %{
      components: for(component <- components, do: component_data(component)),
      next_components: for(component <- next_components, do: component_data(component))
    }
  end

  def next_actions(%{actions: actions}) do
    %{data: for(action <- actions, do: component_data(action))}
  end

  defp component_data(%Component{} = component) do
    %{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name,
      description: component.description,
      component_status: render_component_status(component.component_status),
      requirements: render_requirements(component.requirements),
      dependencies: render_dependencies(component.dependencies),
      child_components: render_child_components(component.child_components),
      inserted_at: component.inserted_at,
      updated_at: component.updated_at
    }
  end

  defp render_component_status(nil), do: nil

  defp render_component_status(status) do
    %{
      design_exists: status.design_exists,
      code_exists: status.code_exists,
      test_exists: status.test_exists,
      spec_exists: status.spec_exists,
      test_status: status.test_status,
      expected_files: status.expected_files,
      actual_files: status.actual_files,
      failing_tests: status.failing_tests,
      computed_at: status.computed_at
    }
  end

  defp render_requirements(nil), do: []

  defp render_requirements(requirements) when is_list(requirements) do
    Enum.map(requirements, fn req ->
      %{
        id: req.id,
        name: req.name,
        type: req.type,
        description: req.description,
        satisfied: req.satisfied,
        satisfied_by: req.satisfied_by,
        details: req.details,
        checked_at: req.checked_at
      }
    end)
  end

  defp render_requirements(_), do: []

  defp render_dependencies(nil), do: []

  defp render_dependencies(dependencies) when is_list(dependencies) do
    Enum.map(dependencies, &component_data/1)
  end

  defp render_dependencies(_), do: []

  defp render_child_components(nil), do: []

  defp render_child_components(child_components) when is_list(child_components) do
    Enum.map(child_components, &component_data/1)
  end

  defp render_child_components(_), do: []
end
