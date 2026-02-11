defmodule CodeMySpec.Requirements.ContextReviewValidityChecker do
  @moduledoc """
  Validates that a context's design review document is valid according to
  the "design_review" document type schema.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  def check(
        %Scope{active_project: project, environment: environment} = _scope,
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
    files = Utils.component_files(component, project)
    review_path = Map.get(files, :review_file)

    {satisfied, details} = validate_review(review_path, environment)

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

  defp validate_review(nil, _environment) do
    {false, %{reason: "No review file path defined for this component type"}}
  end

  defp validate_review(review_path, environment) do
    case Environments.read_file(environment, review_path) do
      {:ok, content} ->
        case Documents.create_dynamic_document(content, "design_review") do
          {:ok, _document} ->
            {true, %{status: "Design review is valid", document_type: "design_review"}}

          {:error, error_message} ->
            {false,
             %{
               reason: "Design review validation failed",
               error: error_message,
               document_type: "design_review"
             }}
        end

      {:error, reason} ->
        {false, %{reason: "Failed to read review file: #{inspect(reason)}"}}
    end
  end
end
