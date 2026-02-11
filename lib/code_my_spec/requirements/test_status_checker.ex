defmodule CodeMySpec.Requirements.TestStatusChecker do
  @moduledoc """
  Checks whether a component's tests are passing by querying persisted Problems.

  Looks for test-source problems associated with the component's test file.
  No problems means tests are passing; problems mean tests are failing.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Problems
  alias CodeMySpec.Requirements.RequirementDefinition
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
    %{test_file: test_file_path} = Utils.component_files(component, scope.active_project)

    test_problems =
      Problems.list_project_problems(scope, source_type: :test, file_path: test_file_path)

    {satisfied, details} =
      if Enum.empty?(test_problems) do
        {true, %{status: "No test problems found"}}
      else
        {false,
         %{
           reason: "Test failures found",
           problem_count: length(test_problems)
         }}
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
end
