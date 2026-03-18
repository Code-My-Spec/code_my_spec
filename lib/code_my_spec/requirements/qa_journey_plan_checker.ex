defmodule CodeMySpec.Requirements.QaJourneyPlanChecker do
  @moduledoc """
  Checks whether a QA journey plan exists and is valid at `.code_my_spec/qa/journey_plan.md`.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @journey_plan_path Paths.qa_journey_plan()

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
      case Environments.read_file(env, @journey_plan_path) do
        {:ok, content} when byte_size(content) > 0 ->
          case Documents.create_dynamic_document(content, "qa_journey_plan") do
            {:ok, _doc} ->
              {true, %{path: @journey_plan_path, status: "Journey plan exists and valid"}}

            {:error, reason} ->
              {false,
               %{
                 reason: "Journey plan invalid: #{inspect(reason)}",
                 path: @journey_plan_path
               }}
          end

        {:ok, _} ->
          {false, %{reason: "Journey plan is empty", path: @journey_plan_path}}

        _ ->
          {false, %{reason: "Journey plan missing", path: @journey_plan_path}}
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
