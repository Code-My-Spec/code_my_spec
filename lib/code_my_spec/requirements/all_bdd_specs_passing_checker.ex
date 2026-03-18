defmodule CodeMySpec.Requirements.AllBddSpecsPassingChecker do
  @moduledoc """
  Checks whether all BDD specs pass across the entire project.

  Queries the Problems table for spex-sourced problems. Satisfied when
  no spex problems exist (all specs pass).
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Problems
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
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
        %Project{} = _project,
        _opts \\ []
      ) do
    problems = Problems.list_project_problems(scope, source: "spex")

    {satisfied, details} =
      if Enum.empty?(problems) do
        {true, %{all_passing: true}}
      else
        {false,
         %{
           failure_count: length(problems),
           failures: Enum.take(problems, 10) |> Enum.map(&problem_to_map/1)
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

  defp problem_to_map(%{} = problem) do
    %{
      file_path: problem.file_path,
      message: problem.message,
      severity: problem.severity,
      line: problem.line
    }
  end
end
