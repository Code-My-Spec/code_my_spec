defmodule CodeMySpec.Requirements.ContextReviewFileChecker do
  @moduledoc """
  Checker for context-level design review file existence.

  This checker verifies that a context has an associated design review file,
  which documents the architectural analysis and validation of the context
  and its child components.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Components.Component
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
    file_key = String.to_existing_atom(name)
    file_path = Map.get(files, file_key)

    {satisfied, details} =
      case Environments.file_exists?(environment, file_path) do
        true ->
          {true, %{status: "File exists", path: file_path}}

        false ->
          {false, %{reason: "File missing", path: file_path}}

        {:error, reason} ->
          {false, %{reason: "Error checking file: #{inspect(reason)}", path: file_path}}
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
