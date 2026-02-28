defmodule CodeMySpec.Requirements.ComponentLinkedChecker do
  @moduledoc """
  Checks whether a story has a linked component that is a surface type
  (controller, live_context, liveview, liveview_component).
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @surface_types ~w(controller live_context liveview liveview_component)

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
    {satisfied, details} = evaluate_component_link(scope, story)

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

  defp evaluate_component_link(_scope, %Story{component_id: nil}) do
    {false, %{reason: "No component linked to story"}}
  end

  defp evaluate_component_link(scope, %Story{component_id: component_id}) do
    case Components.get_component(scope, component_id) do
      nil ->
        {false, %{reason: "Linked component not found", component_id: component_id}}

      component ->
        validate_surface_type(component)
    end
  end

  defp validate_surface_type(component) do
    if component.type in @surface_types do
      {true, %{component_id: component.id, component_type: component.type}}
    else
      {false,
       %{
         reason: "Component type '#{component.type}' is not a surface type",
         component_id: component.id,
         expected_types: @surface_types
       }}
    end
  end
end
