defmodule Mix.Tasks.ResetOnboarding do
  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  import Ecto.Query

  alias CodeMySpec.Accounts.{Account, Member}
  alias CodeMySpec.Agents.ModelSetting
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.UserPreferences.DesktopUser
  alias CodeMySpec.Users.User

  @shortdoc "Reset desktop onboarding to models (1), account (2), or project (3)"
  @moduledoc """
  Resets the desktop user's onboarding in the configured SQLite database.

      mix reset_onboarding
      mix reset_onboarding 1
      mix reset_onboarding 2
      mix reset_onboarding 3
      CMS_DESKTOP_DB=/tmp/codemyspec-onboarding-preview.db mix reset_onboarding

  No argument means step 1. Step 1 deletes model selections, owned accounts,
  and their projects; step 2 keeps models; step 3 keeps models and accounts.
  Project database data is deleted, but project files, the desktop user,
  provider credentials, and harness authorization are preserved.

  Defaults to MIX_ENV=desktop. Uses CMS_DESKTOP_DB, otherwise
  ~/.codemyspec/desktop.db. Does not start the desktop app or harness.
  Creates a SQLite backup beside the database before changing it. Refuses
  shared accounts. Refresh /app after running; stop any running agent first.
  """

  @impl true
  def run(args) do
    step = parse_step!(args)
    Mix.Task.run("app.config")

    unless Repo.__adapter__() == Ecto.Adapters.SQLite3,
      do: Mix.raise("reset_onboarding requires the desktop SQLite database (MIX_ENV=desktop)")

    database = Repo.config() |> Keyword.fetch!(:database) |> Path.expand()
    unless File.regular?(database), do: Mix.raise("Database does not exist: #{database}")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        user =
          repo.get_by(User, email: DesktopUser.email()) ||
            Mix.raise("No desktop user in #{database}")

        backup =
          database <>
            ".before-onboarding-reset-" <> Integer.to_string(System.os_time(:microsecond))

        repo.query!("VACUUM INTO ?", [backup])
        File.chmod!(backup, 0o600)
        Mix.shell().info("Backup: #{backup}")
        reset(repo, user.id, step)
      end)

    case result do
      {:ok, :ok} -> Mix.shell().info("Reset #{database} to step #{step}. Refresh /app.")
      {:error, reason} -> Mix.raise("Reset rolled back: #{inspect(reason)}")
    end
  end

  @doc false
  def parse_step!([]), do: 1
  def parse_step!([step]) when step in ["1", "2", "3"], do: String.to_integer(step)
  def parse_step!(_), do: Mix.raise("Usage: mix reset_onboarding [1|2|3]")

  @doc false
  def reset(repo, user_id, step) when step in 1..3 do
    repo.transaction(fn ->
      account_ids =
        repo.all(
          from m in Member,
            where: m.user_id == ^user_id and m.role == :owner,
            select: m.account_id
        )

      if repo.exists?(
           from m in Member, where: m.account_id in ^account_ids and m.user_id != ^user_id
         ),
         do: repo.rollback(:shared_accounts)

      # Preferences have no database foreign keys; clear them before deletion.
      repo.update_all(from(p in "user_preferences", where: p.user_id == ^user_id),
        set: [active_project_id: nil]
      )

      repo.delete_all(from p in Project, where: p.account_id in ^account_ids)

      if step <= 2 do
        repo.update_all(from(p in "user_preferences", where: p.user_id == ^user_id),
          set: [active_account_id: nil]
        )

        repo.delete_all(from r in "rules", where: r.account_id in ^account_ids)
        repo.delete_all(from a in Account, where: a.id in ^account_ids)
      end

      if step == 1, do: repo.delete_all(from m in ModelSetting, where: m.user_id == ^user_id)
      :ok
    end)
  end
end
