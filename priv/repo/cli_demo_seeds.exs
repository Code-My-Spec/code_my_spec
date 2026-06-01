# Harness-side seed (cli_demo.db, SQLite, MIX_ENV=cli_demo)
#
# Wires the cli_demo harness to the demo server's access token and clears
# project/client state so a genesis session replay starts from nothing
# (init_project will recreate the project with id 49d80233 from the server).
#
# Usage: CMS_OAUTH_TOKEN=<token> MIX_ENV=cli_demo mix run priv/repo/cli_demo_seeds.exs
#        (stop the harness first to avoid SQLite write contention)

alias CodeMySpec.{Repo, ClientUsers}
alias CodeMySpec.Projects.Project
alias CodeMySpec.ClientUsers.ClientUser

token = System.get_env("CMS_OAUTH_TOKEN") || raise "set CMS_OAUTH_TOKEN to the demo access token"

expires_at = DateTime.utc_now() |> DateTime.add(365, :day) |> DateTime.truncate(:second)

# Clean slate — genesis rebuilds everything.
{projects_deleted, _} = Repo.delete_all(Project)
{users_deleted, _} = Repo.delete_all(ClientUser)
IO.puts("  cleared #{projects_deleted} project(s), #{users_deleted} client_user(s)")

# id = 1 matches the demo server's user id so init_project's client_user_id wiring lines up.
{:ok, cu} =
  ClientUsers.create_client_user(%{
    id: 1,
    email: "demo@codemyspec.local",
    oauth_token: token,
    oauth_expires_at: expires_at
  })

IO.puts("  client_user wired: id=#{cu.id} email=#{cu.email} (token set, expires #{expires_at})")
