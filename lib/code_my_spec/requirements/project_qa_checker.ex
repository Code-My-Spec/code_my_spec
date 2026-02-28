defmodule CodeMySpec.Requirements.ProjectQaChecker do
  @moduledoc """
  Checks whether a QA summary exists for the project at `.code_my_spec/qa/summary.md`.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Environments
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @qa_summary_path ".code_my_spec/qa/summary.md"

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
      case Environments.file_exists?(env, @qa_summary_path) do
        true ->
          {true, %{path: @qa_summary_path, status: "QA summary exists"}}

        false ->
          {false, %{reason: "QA summary missing", path: @qa_summary_path}}

        {:error, reason} ->
          {false,
           %{reason: "Error checking QA summary: #{inspect(reason)}", path: @qa_summary_path}}
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
