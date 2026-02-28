defmodule CodeMySpec.Requirements.StoryQaChecker do
  @moduledoc """
  Checks whether QA artifacts exist for a story at `.code_my_spec/qa/{story_id}/result.md`.
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
    qa_path = ".code_my_spec/qa/#{story.id}/result.md"
    env = scope.environment

    {satisfied, details} =
      case Environments.file_exists?(env, qa_path) do
        true ->
          {true, %{path: qa_path, status: "QA result exists"}}

        false ->
          {false, %{reason: "QA result missing", path: qa_path}}

        {:error, reason} ->
          {false, %{reason: "Error checking QA result: #{inspect(reason)}", path: qa_path}}
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
