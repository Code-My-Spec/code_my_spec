defmodule CodeMySpec.Requirements.FileExistenceChecker do
  @moduledoc """
  Checks whether expected component files (spec, implementation, test, etc.) exist on disk.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  def check(
        %Scope{active_project: project} = scope,
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
    file_key = file_key(name)
    file_path = Map.get(files, file_key)
    environment = scope.environment

    Logger.debug(
      "[FileExistenceChecker] #{component.module_name} (#{component.type}) #{name} -> #{file_path}"
    )

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

  def file_key("spec_file"), do: :spec_file
  def file_key("code_file"), do: :code_file
  def file_key("implementation_file"), do: :code_file
  def file_key("test_file"), do: :test_file
  def file_key("review_file"), do: :review_file
end
