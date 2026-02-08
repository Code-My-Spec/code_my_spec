defmodule CodeMySpec.Requirements.DocumentValidityChecker do
  @moduledoc """
  Validates that a document file contains valid content according to its document type definition.
  Uses CodeMySpec.Documents.create_dynamic_document/2 to validate the document structure.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry
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
        %Component{type: component_type} = component,
        _opts \\ []
      ) do
    # Get document_type from component type definition
    type_def = Registry.get_type(component_type)
    document_type = Map.get(type_def, :document_type)

    {satisfied, details} = validate_document(component, project, document_type, environment)

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

  defp validate_document(%Component{} = component, project, document_type, environment) do
    files = Utils.component_files(component, project)
    spec_path = Map.get(files, :spec_file)

    case Environments.read_file(environment, spec_path) do
      {:ok, content} ->
        case Documents.create_dynamic_document(content, document_type) do
          {:ok, _document} ->
            {true, %{status: "Document is valid", document_type: document_type}}

          {:error, error_message} ->
            {false,
             %{
               reason: "Document validation failed",
               error: error_message,
               document_type: document_type
             }}
        end

      {:error, reason} ->
        {false, %{reason: "Failed to read spec file: #{inspect(reason)}"}}
    end
  end
end
