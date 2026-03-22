defmodule CodeMySpec.Requirements.DependencyChecker do
  @behaviour CodeMySpec.Requirements.CheckerBehaviour

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
        %Component{dependencies: dependencies},
        _opts \\ []
      ) do
    {satisfied, details, depends_on} =
      case {String.to_existing_atom(name), dependencies} do
        {:dependencies_satisfied, []} ->
          {true, %{status: "No dependencies to satisfy"}, []}

        {:dependencies_satisfied, deps} when is_list(deps) ->
          all_satisfied = Enum.all?(deps, &dependency_satisfied?/1)

          dep_edges =
            Enum.map(deps, fn dep ->
              %{
                "entity_type" => "component",
                "entity_id" => dep.id,
                "requirement_name" => "tests_passing"
              }
            end)

          if all_satisfied do
            {true, %{status: "All dependencies satisfied", count: length(deps)}, dep_edges}
          else
            unsatisfied_deps =
              deps
              |> Enum.reject(&dependency_satisfied?/1)
              |> Enum.map(& &1.name)

            {false,
             %{
               reason: "Some dependencies not satisfied",
               unsatisfied_dependencies: unsatisfied_deps,
               total_dependencies: length(deps),
               unsatisfied_count: length(unsatisfied_deps)
             }, dep_edges}
          end

        {:dependencies_satisfied, %Ecto.Association.NotLoaded{}} ->
          {false, %{reason: "Dependencies not loaded"}, []}

        {_, _} ->
          {false, %{reason: "Invalid dependency structure"}, []}
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
      depends_on: depends_on
    }
  end

  defp dependency_satisfied?(%Component{requirements: requirements}) when is_list(requirements) do
    # All requirements must be satisfied
    Enum.all?(requirements, fn req -> req.satisfied end)
  end

  defp dependency_satisfied?(%Component{requirements: %Ecto.Association.NotLoaded{}}) do
    # If requirements not loaded, assume not satisfied for safety
    false
  end

  defp dependency_satisfied?(_), do: false
end
