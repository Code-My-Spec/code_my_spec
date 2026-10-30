defmodule Mix.Tasks.Cms.MigrationDryRun do
  @shortdoc "Try a legacy export against a throwaway project, then roll it back"
  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Migration
  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [export: :string, project: :string, user: :string])

    if args != [] or invalid != [] or
         Enum.any?([:export, :project, :user], &is_nil(opts[&1])) do
      Mix.raise(
        "Usage: mix cms.migration_dry_run --export PATH --project THROWAWAY_UUID --user EMAIL"
      )
    end

    Mix.Task.run("app.start")
    scope = scope_for!(opts[:user], opts[:project])

    case Migration.dry_run_file(scope, opts[:export]) do
      {:ok, report} ->
        Mix.shell().info(Jason.encode!(report, pretty: true))
        if report.status == :refused, do: exit({:shutdown, 1})

      {:error, reason} ->
        Mix.raise("Could not read export: #{inspect(reason)}")
    end
  end

  defp scope_for!(email, project_id) do
    user = Users.get_user_by_email(email) || Mix.raise("User not found")
    base = %Scope{user: user, user_id: user.id}

    project =
      case Projects.get_project_for_user(base, project_id) do
        {:ok, project} -> project
        {:error, :not_found} -> Mix.raise("Project not found for user")
      end

    account = Repo.get!(Account, project.account_id)

    %{
      base
      | active_account: account,
        active_account_id: account.id,
        active_project: project,
        active_project_id: project.id
    }
  end
end
