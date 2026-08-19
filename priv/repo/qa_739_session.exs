# Mint a session for the QA user and point it at the QA Fixture Project.
#
# The documented login is a magic link through /dev/mailbox, and that mailbox is
# shared: taking the newest link can log you in as whichever QA user another
# agent just seeded. Minting the token directly is the same code path the
# controller uses (`Users.generate_user_session_token/1`), without the race.
#
# Also sets active_account_id / active_project_id, so the session lands on the
# fixture project rather than wherever the user last was.
#
#   mix cms.seed priv/repo/qa_739_session.exs

import Ecto.Query

alias CodeMySpec.Repo
alias CodeMySpec.UserPreferences
alias CodeMySpec.Users
alias CodeMySpec.Users.Scope
alias CodeMySpec.Users.User

project_id = "11111111-1111-4111-8111-111111111111"
email = "qa@codemyspec.local"

user = Repo.one(from u in User, where: u.email == ^email)

if is_nil(user) do
  raise "no #{email} — run `mix cms.seed priv/repo/qa_seeds.exs` first"
end

# Schemaless select returns the raw 16 bytes; the changeset wants the string.
account_id =
  Repo.one(
    from p in "projects",
      where: p.id == type(^project_id, :binary_id),
      select: p.account_id
  )
  |> then(fn
    id when is_binary(id) and byte_size(id) == 16 -> Ecto.UUID.load!(id)
    id -> id
  end)

scope = %Scope{user: user}
{:ok, _} = UserPreferences.select_active_account(scope, account_id)
{:ok, _} = UserPreferences.select_active_project(scope, project_id)

# A magic-link token, not a session token. The remember-me cookie is signed by
# the endpoint, so a raw session token in a cookie authenticates nothing; the
# login URL is a plain path and does. Same builder the mailer uses.
{encoded, user_token} = CodeMySpec.Users.UserToken.build_email_token(user, "login")
{:ok, _} = Repo.insert(user_token)

IO.puts("""

QA session for #{email}
  user_id:    #{user.id}
  account_id: #{account_id}
  project_id: #{project_id}

Log in by following this once (single use):
  http://127.0.0.1:4000/users/log-in/#{encoded}

Then the fixture project is already active, so
  http://127.0.0.1:4000/app/projects/#{project_id}/files
renders the harness picker with both seeded harnesses.
""")
