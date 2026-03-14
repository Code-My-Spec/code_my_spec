defmodule CodeMySpec.Requirements.BddSpecPassingChecker do
  @moduledoc """
  Checks whether BDD specs pass for a story.

  Reads cached spex problems from the Problems table instead of running specs
  inline. Specs are run in batches at start/stop of implementation and results
  are persisted as Problems.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Problems
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
    env = scope.environment
    specs = BddSpecs.list_specs_for_story(env, story.id)

    {satisfied, details} =
      cond do
        specs == [] ->
          {false, %{reason: "No BDD spec files to run for story #{story.id}"}}

        true ->
          spec_file_paths = Enum.map(specs, & &1.file_path) |> MapSet.new()

          spex_problems =
            scope
            |> Problems.list_project_problems(source: "spex")
            |> Enum.filter(&MapSet.member?(spec_file_paths, &1.file_path))

          if spex_problems == [] do
            {true, %{spec_count: length(specs), all_passing: true}}
          else
            {false,
             %{
               spec_count: length(specs),
               failure_count: length(spex_problems),
               failures: Enum.map(spex_problems, &problem_to_map/1)
             }}
          end
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
