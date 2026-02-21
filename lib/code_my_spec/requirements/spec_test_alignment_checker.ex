defmodule CodeMySpec.Requirements.SpecTestAlignmentChecker do
  @moduledoc """
  Checks whether the test file implements all (and only) the test assertions from the spec.

  Calls SpecAlignment.run/2 and filters results to "missing_test" and "extra_test" categories.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  def check(
        %Scope{} = scope,
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
    %{spec_file: spec_file} = Utils.component_files(component, scope.active_project)

    {satisfied, details} =
      case resolve_and_check(scope, spec_file) do
        {:ok, problems} ->
          test_problems =
            Enum.filter(problems, &(&1.category in ["missing_test", "extra_test"]))

          if test_problems == [] do
            {true, %{status: "All spec test assertions are implemented"}}
          else
            {false,
             %{
               reason: "Test alignment issues",
               problems: Enum.map(test_problems, & &1.message)
             }}
          end

        {:error, reason} ->
          {false, %{reason: "Could not check alignment: #{reason}"}}
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
      details: details
    }
  end

  defp resolve_and_check(%Scope{cwd: nil}, _spec_file), do: {:error, "No cwd"}

  defp resolve_and_check(%Scope{cwd: cwd} = scope, spec_file) do
    absolute_path = Path.join(cwd, spec_file)
    SpecAlignment.run(scope, paths: [absolute_path])
  end
end
