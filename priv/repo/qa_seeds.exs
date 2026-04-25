# QA Seeds — Server (Postgres)
#
# Creates the minimum fixture needed to QA the hosted endpoint (`:4000`):
# user + personal account + membership + project linked via local_path.
#
# Usage: mix run priv/repo/qa_seeds.exs
#
# Idempotent — safe to re-run. Prints credentials at the end so the QA agent
# can reuse them without spelunking the source.

import Ecto.Query

alias CodeMySpec.Repo
alias CodeMySpec.Accounts
alias CodeMySpec.Accounts.Member
alias CodeMySpec.Projects.Project
alias CodeMySpec.Users
alias CodeMySpec.Users.Scope

email = "qa@codemyspec.local"
password = "qa-password-123!"
account_slug = "qa-account"
project_id = "11111111-1111-4111-8111-111111111111"
project_name = "QA Fixture Project"
project_module = "QaFixtureProject"
local_path = File.cwd!()

IO.puts("\n=== QA Seeds — server ===")

# 1. User
user =
  case Users.get_user_by_email(email) do
    nil ->
      {:ok, user} = Users.register_user(%{email: email})
      {:ok, {user, _expired_tokens}} = Users.update_user_password(user, %{password: password})
      IO.puts("  user: created #{email}")
      user

    user ->
      IO.puts("  user: exists #{email}")
      user
  end

scope = Scope.for_user(user)

# 2. Personal account (idempotent by slug)
account =
  case Repo.one(from a in Accounts.Account, where: a.slug == ^account_slug) do
    nil ->
      {:ok, account} =
        Accounts.create_account(scope, %{
          name: "QA Account",
          slug: account_slug,
          type: :personal
        })

      IO.puts("  account: created #{account_slug}")
      account

    account ->
      IO.puts("  account: exists #{account_slug}")
      account
  end

# 3. Member (owner)
case Repo.one(
       from m in Member, where: m.user_id == ^user.id and m.account_id == ^account.id
     ) do
  nil ->
    %Member{}
    |> Member.changeset(%{user_id: user.id, account_id: account.id, role: :owner})
    |> Repo.insert!()

    IO.puts("  member: created #{email} as owner of #{account_slug}")

  _existing ->
    IO.puts("  member: exists")
end

# 4. Project linked to this checkout via local_path. Bootstrap changeset
#    accepts id + account_id directly (no scope dependency).
project =
  case Repo.get(Project, project_id) do
    nil ->
      {:ok, project} =
        %Project{}
        |> Project.bootstrap_changeset(%{
          id: project_id,
          name: project_name,
          module_name: project_module,
          account_id: account.id,
          local_path: local_path,
          status: :created
        })
        |> Repo.insert()

      IO.puts("  project: created #{project_name} (local_path=#{local_path})")
      project

    project ->
      if project.local_path != local_path do
        {:ok, project} =
          project
          |> Ecto.Changeset.change(local_path: local_path)
          |> Repo.update()

        IO.puts("  project: updated local_path -> #{local_path}")
        project
      else
        IO.puts("  project: exists (#{project_name})")
        project
      end
  end

IO.puts("""

=== QA Fixture (server) ===
Hosted UI:    http://127.0.0.1:4000
Email:        #{email}
Password:     #{password}
Account slug: #{account_slug}
Account id:   #{account.id}
Project id:   #{project.id}
Local path:   #{local_path}

Login at /users/log-in (password form), then visit /app.
For local web (port 4003), the same project resolves via X-Working-Dir or
Plugs.WorkingDirScope as long as `local_path` matches PWD on each request.
""")
