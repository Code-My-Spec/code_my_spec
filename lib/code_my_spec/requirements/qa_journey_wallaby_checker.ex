defmodule CodeMySpec.Requirements.QaJourneyWallabyChecker do
  @moduledoc """
  Checks whether at least one Wallaby journey test exists under `test/journeys/`.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @wallaby_dir Paths.qa_journey_wallaby_dir()
  @wallaby_glob Path.join(@wallaby_dir, "*_test.exs")

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
      case Environments.glob(env, @wallaby_glob) do
        files when is_list(files) and files != [] ->
          {true, %{path: @wallaby_dir, status: "#{length(files)} journey test(s) found"}}

        _ ->
          {false, %{reason: "No journey tests found", path: @wallaby_dir}}
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
