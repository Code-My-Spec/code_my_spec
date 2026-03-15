defmodule CodeMySpec.Requirements.StoryQaChecker do
  @moduledoc """
  Checks whether QA is complete for a story.

  Satisfied when `result_complete.md` exists at `.code_my_spec/qa/{story_id}/`.
  This file is created by QaStory.evaluate when all QA scenarios pass.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Environments
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
    complete_path = ".code_my_spec/qa/#{story.id}/result_complete.md"
    env = scope.environment

    {satisfied, details} =
      if Environments.file_exists?(env, complete_path) do
        {true, %{path: complete_path, status: "QA passed"}}
      else
        {false, %{reason: "QA not complete — result_complete.md missing", path: complete_path}}
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
