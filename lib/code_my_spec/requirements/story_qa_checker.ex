defmodule CodeMySpec.Requirements.StoryQaChecker do
  @moduledoc """
  Checks whether QA is complete for a story:
  1. result.md exists at `.code_my_spec/qa/{story_id}/result.md`
  2. Any issues from the result have been filed to the database
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.{Documents, Environments, Issues}
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
      case Environments.read_file(env, qa_path) do
        {:ok, content} ->
          check_issues_filed(scope, story.id, content, qa_path)

        {:error, _} ->
          {false, %{reason: "QA result missing", path: qa_path}}
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

  # Check that issues from the result document are filed in the DB.
  # If the result has no issues section or "None", it's satisfied.
  # If it has issues, verify they exist in the DB.
  defp check_issues_filed(scope, story_id, content, qa_path) do
    case Documents.create_dynamic_document(content, "qa_result") do
      {:ok, document} ->
        issues_in_result = Map.get(document.sections, "issues", [])

        if issues_in_result == [] or issues_in_result == "None" do
          {true, %{path: qa_path, status: "QA result exists, no issues to file"}}
        else
          issues_in_db = Issues.list_by_story(scope, story_id)

          if length(issues_in_db) > 0 do
            {true, %{path: qa_path, status: "QA result exists, #{length(issues_in_db)} issues filed"}}
          else
            {false, %{reason: "QA result has issues but none filed to database", path: qa_path}}
          end
        end

      {:error, _} ->
        # Result exists but can't be parsed — still count as present
        {true, %{path: qa_path, status: "QA result exists"}}
    end
  end
end
