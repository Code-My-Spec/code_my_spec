defmodule CodeMySpec.Requirements.QaJourneyExecuteChecker do
  @moduledoc """
  Checks whether a QA journey result exists and is valid at `.code_my_spec/qa/journey_result.md`.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @journey_result_path Paths.qa_journey_result()

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        %Project{},
        _opts \\ []
      ) do
    env = scope.environment

    {satisfied, details} =
      case Environments.read_file(env, @journey_result_path) do
        {:ok, content} when byte_size(content) > 0 ->
          case Documents.create_dynamic_document(content, "qa_journey_result") do
            {:ok, _doc} ->
              {true, %{path: @journey_result_path, status: "Journey result exists and valid"}}

            {:error, reason} ->
              {false,
               %{
                 reason: "Journey result invalid: #{inspect(reason)}",
                 path: @journey_result_path
               }}
          end

        {:ok, _} ->
          {false, %{reason: "Journey result is empty", path: @journey_result_path}}

        _ ->
          {false, %{reason: "Journey result missing", path: @journey_result_path}}
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
