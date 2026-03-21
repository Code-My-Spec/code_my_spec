defmodule CodeMySpec.Requirements.ProjectSetupChecker do
  @moduledoc """
  Checker that verifies a project's bootstrap setup is complete.

  Delegates to `ProjectSetup.check_status/2` and checks all required
  setup steps (deps, compilers, project structure, CLI config, etc.).
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @required_keys [
    :elixir_installed,
    :phoenix_project_exists,
    :codemyspec_deps_installed,
    :compilers_configured,
    :project_dir_exists,
    :project_structure_complete,
    :app_symlinks_installed,
    :agents_md_installed,
    :rules_installed,
    :claude_md_installed,
    :cli_config_has_project_id
  ]

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        _entity,
        _opts \\ []
      ) do
    env = scope.environment

    {satisfied, score, details} =
      if env && env.cwd do
        status = ProjectSetup.check_status(env, %{})

        passing =
          Enum.count(@required_keys, fn key -> Map.get(status, key, false) end)

        total = length(@required_keys)
        all_pass = passing == total

        failing =
          @required_keys
          |> Enum.reject(fn key -> Map.get(status, key, false) end)
          |> Enum.map(&Atom.to_string/1)

        {all_pass, passing / total,
         %{
           passing: passing,
           total: total,
           failing: failing
         }}
      else
        {false, 0.0, %{reason: "No working directory available"}}
      end

    %{
      name: name,
      artifact_type: artifact_type,
      description: description,
      checker_module: checker,
      satisfied_by: satisfied_by,
      satisfied: satisfied,
      score: Float.round(score, 2),
      checked_at: DateTime.utc_now(),
      details: details
    }
  end
end
