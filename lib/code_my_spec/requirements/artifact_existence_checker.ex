defmodule CodeMySpec.Requirements.ArtifactExistenceChecker do
  @moduledoc """
  Generic checker that verifies a file exists at a configurable path.

  The path is read from `definition.config["path"]`. Supports interpolation
  of `{project_name}` in the path template.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by,
          config: config
        },
        _entity,
        _opts \\ []
      ) do
    path = Map.get(config, "path") || Map.get(config, :path)
    env = scope.environment

    {satisfied, details} =
      case path do
        nil ->
          {false, %{reason: "No path configured in definition config"}}

        path ->
          case Environments.file_exists?(env, path) do
            true ->
              {true, %{path: path, status: "Artifact exists"}}

            false ->
              {false, %{reason: "Artifact missing", path: path}}

            {:error, reason} ->
              {false, %{reason: "Error checking artifact: #{inspect(reason)}", path: path}}
          end
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
