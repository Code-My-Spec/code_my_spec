defmodule CodeMySpec.Requirements.ComponentCompleteChecker do
  @moduledoc """
  Checks whether the linked component tree (root + all descendants)
  has all requirements satisfied.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        %Story{} = story,
        _opts \\ []
      ) do
    {satisfied, details} = evaluate(scope, story)

    %{
      name: name,
      artifact_type: artifact_type,
      description: description,
      checker_module: checker,
      satisfied_by: satisfied_by,
      satisfied: satisfied,
      score: if(satisfied, do: 1.0, else: 0.0),
      checked_at: DateTime.utc_now(),
      details: details
    }
  end

  defp evaluate(_scope, %Story{component_id: nil}) do
    {false, %{reason: "No component linked"}}
  end

  defp evaluate(scope, %Story{component_id: component_id}) do
    case ComponentRepository.get_component(scope, component_id) do
      nil ->
        {false, %{reason: "Linked component not found"}}

      root ->
        descendants = ComponentRepository.list_all_descendants(scope, component_id)
        all_components = [root | descendants]

        all_requirements =
          all_components
          |> Enum.flat_map(fn c -> c.requirements || [] end)

        unsatisfied =
          Enum.reject(all_requirements, & &1.satisfied)

        if unsatisfied == [] do
          {true,
           %{
             component_count: length(all_components),
             requirement_count: length(all_requirements),
             all_satisfied: true
           }}
        else
          {false,
           %{
             component_count: length(all_components),
             requirement_count: length(all_requirements),
             unsatisfied_count: length(unsatisfied),
             unsatisfied:
               Enum.map(unsatisfied, fn r ->
                 %{requirement: r.name, component_id: r.component_id}
               end)
           }}
        end
    end
  end
end
