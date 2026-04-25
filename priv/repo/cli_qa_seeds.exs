# QA Seeds — Local CLI (SQLite)
#
# Creates the minimum fixture for QA against the CLI binary's local DB
# (`priv/repo/cli_dev.db` in dev_cli, the bundled DB in prod_cli).
#
# Usage: MIX_ENV=dev_cli mix run priv/repo/cli_qa_seeds.exs
#
# The local schema is account-less — `WorkingDirScope` only needs a Project row
# with `local_path` matching the request's working dir to resolve a scope.
# An optional `ClientUser` is stamped so `bootstrap/auth/status` reports
# "authenticated" without an OAuth round-trip.
#
# Idempotent — safe to re-run.

alias CodeMySpec.ClientUsers
alias CodeMySpec.Projects.Project
alias CodeMySpec.Repo

email = "qa@codemyspec.local"
account_id = 1
project_id = "11111111-1111-4111-8111-111111111111"
project_name = "QA Fixture Project"
project_module = "QaFixtureProject"
local_path = File.cwd!()

IO.puts("\n=== QA Seeds — local CLI ===")

# 1. Optional client_user (lets /api/bootstrap/auth/status report authenticated).
case ClientUsers.get_client_user_by_email(email) do
  nil ->
    {:ok, _} =
      ClientUsers.create_client_user(%{
        email: email,
        oauth_token: "qa-fake-token",
        oauth_expires_at: DateTime.add(DateTime.utc_now(), 30, :day) |> DateTime.truncate(:second)
      })

    IO.puts("  client_user: created #{email}")

  _existing ->
    IO.puts("  client_user: exists #{email}")
end

# 2. Project with local_path. Local schema has no scope/account FK enforcement
#    on the SQLite side, so we use bootstrap_changeset and stamp account_id
#    with a sentinel value the local app doesn't dereference.
case Repo.get(Project, project_id) do
  nil ->
    {:ok, _project} =
      %Project{}
      |> Project.bootstrap_changeset(%{
        id: project_id,
        name: project_name,
        module_name: project_module,
        account_id: account_id,
        local_path: local_path,
        status: :created
      })
      |> Repo.insert()

    IO.puts("  project: created #{project_name} (local_path=#{local_path})")

  project ->
    if project.local_path != local_path do
      project
      |> Ecto.Changeset.change(local_path: local_path)
      |> Repo.update!()

      IO.puts("  project: updated local_path -> #{local_path}")
    else
      IO.puts("  project: exists (#{project_name})")
    end
end

IO.puts("""

=== QA Fixture (local CLI) ===
Local UI:    http://127.0.0.1:4003/projects/qa-fixture-project
Health:      http://127.0.0.1:4003/health
Auth status: http://127.0.0.1:4003/api/bootstrap/auth/status
Project id:  #{project_id}
Local path:  #{local_path}

The WorkingDirScope plug resolves this project on every request whose
X-Working-Dir header (or process cwd, for the binary) matches the local_path.
""")
