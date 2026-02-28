defmodule CodeMySpec.Requirements.BddSpecExistenceChecker do
  @moduledoc """
  Checks whether BDD spec files exist for a story.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.BddSpecs
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
      if specs != [] do
        {true, %{spec_count: length(specs), spec_files: Enum.map(specs, & &1.file_path)}}
      else
        {false, %{reason: "No BDD spec files found for story #{story.id}"}}
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
