defmodule CodeMySpec.Requirements.HierarchicalChecker do
  @moduledoc false
  @behaviour CodeMySpec.Requirements.CheckerBehaviour
  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  def check(
        %Scope{},
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        } = _requirement_definition,
        %Component{} = component,
        _opts \\ []
      ) do
    {satisfied, details, child_depends_on} =
      case name do
        "children_designs" ->
          # Check spec_file for satisfaction, edge to spec_valid (design completion)
          {sat, det, _} = check_children_requirements(component, "spec_file")
          edges = collect_child_edges(get_children(component), "spec_valid")
          {sat, det, edges}

        "children_implementations" ->
          check_children_requirements(component, "implementation_file")

        "children_tests" ->
          check_children_requirements(component, "test_file")

        "children_complete" ->
          check_all_children_requirements(component)

        _ ->
          Logger.error("#{__MODULE__} was passed a registry spec with an invalid name #{name}.")
          {false, %{reason: "Invalid hierarchical requirement type"}, []}
      end

    %{
      name: name,
      artifact_type: artifact_type,
      description: description,
      checker_module: checker,
      satisfied_by: satisfied_by,
      satisfied: satisfied,
      score: if(satisfied, do: 1.0, else: 0.0),
      checked_at: DateTime.utc_now(),
      details: details,
      depends_on: child_depends_on
    }
  end

  defp check_children_requirements(
         %Component{child_components: %Ecto.Association.NotLoaded{}} = component,
         _requirement_name
       ) do
    Logger.error(
      "#{__MODULE__} was passed a component with child components not loaded: #{inspect(component.id)}"
    )

    {false, %{reason: "Child components not loaded"}, []}
  end

  defp check_children_requirements(%Component{child_components: []}, _requirement_name) do
    {true, %{status: "No child components to check", count: 0}, []}
  end

  defp check_children_requirements(%Component{child_components: children}, requirement_name)
       when is_list(children) do
    all_satisfied = all_children_have_requirement?(children, requirement_name)
    depends_on = collect_child_edges(children, requirement_name)

    if all_satisfied do
      {true, %{status: "All child components have required #{requirement_name}"}, depends_on}
    else
      {false, %{reason: "Some child components missing #{requirement_name}"}, depends_on}
    end
  end

  defp check_all_children_requirements(%Component{
         child_components: %Ecto.Association.NotLoaded{}
       }) do
    {false, %{reason: "Child components not loaded"}, []}
  end

  defp check_all_children_requirements(%Component{child_components: []}) do
    {true, %{status: "No child components to check", count: 0}, []}
  end

  defp check_all_children_requirements(%Component{child_components: children})
       when is_list(children) do
    all_complete = all_children_complete?(children)
    depends_on = collect_child_edges(children, "tests_passing")

    if all_complete do
      {true, %{status: "All child components fully complete"}, depends_on}
    else
      {false, %{reason: "Some child components not fully complete"}, depends_on}
    end
  end

  defp collect_child_edges(children, requirement_name) do
    Enum.flat_map(children, fn child ->
      edge = %{
        "entity_type" => "component",
        "entity_id" => child.id,
        "requirement_name" => requirement_name
      }

      nested = collect_child_edges(get_children(child), requirement_name)
      [edge | nested]
    end)
  end

  defp all_children_have_requirement?([], _requirement_name), do: true

  defp all_children_have_requirement?([component | rest], requirement_name) do
    has_requirement?(component, requirement_name) and
      all_children_have_requirement?(get_children(component), requirement_name) and
      all_children_have_requirement?(rest, requirement_name)
  end

  defp all_children_complete?([]), do: true

  defp all_children_complete?([component | rest]) do
    fully_complete?(component) and
      all_children_complete?(get_children(component)) and
      all_children_complete?(rest)
  end

  defp get_children(%Component{child_components: %Ecto.Association.NotLoaded{}}), do: []
  defp get_children(%Component{child_components: children}) when is_list(children), do: children
  defp get_children(_), do: []

  defp has_requirement?(%Component{requirements: requirements}, requirement_name)
       when is_list(requirements) do
    Enum.any?(requirements, fn req ->
      req.name == requirement_name and req.satisfied
    end)
  end

  defp has_requirement?(entity, requirement_name) do
    Logger.error(
      "#{__MODULE__}.has_requirement?/2 called with unexpected args: " <>
        "entity=#{inspect(entity, limit: 3)}, requirement_name=#{inspect(requirement_name)}"
    )

    false
  end

  defp fully_complete?(%Component{requirements: %Ecto.Association.NotLoaded{}}), do: false
  defp fully_complete?(%Component{requirements: []}), do: true

  defp fully_complete?(%Component{requirements: requirements}) when is_list(requirements) do
    # Component is fully complete if all its requirements are satisfied
    Enum.all?(requirements, fn req -> req.satisfied end)
  end

  defp fully_complete?(_), do: false
end
