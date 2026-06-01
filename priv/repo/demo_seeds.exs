# Demo Seeds — server (Postgres, MIX_ENV=demo)
#
# Seeds the auth + project that the recorded harness sessions expect, so a full
# session replay can run against the demo server (:4006) without interactive
# OAuth. Idempotent. Prints the access token to paste into the cli_demo harness
# (client_users.oauth_token) via the harness-side seed.
#
# Usage: MIX_ENV=demo mix run priv/repo/demo_seeds.exs

import Ecto.Query

alias CodeMySpec.{Repo, Accounts, Users, UserPreferences}
alias CodeMySpec.Users.Scope
alias CodeMySpec.Projects.Project
alias CodeMySpec.Oauth.AccessToken

email = "demo@codemyspec.local"
account_slug = "demo-replay"
# The exact project id the recorded genesis session calls init_project with.
project_id = "49d80233-5e7f-4590-8fff-e6af922ce70d"
cli_oauth_uid = "codemyspec-cli"
now = DateTime.utc_now() |> DateTime.truncate(:second)

IO.puts("\n=== Demo Seeds — server (:4006) ===")

# 1. User
user =
  case Users.get_user_by_email(email) do
    nil ->
      {:ok, u} = Users.register_user(%{email: email})
      IO.puts("  user: created #{email}")
      u

    u ->
      IO.puts("  user: exists #{email}")
      u
  end

scope = Scope.for_user(user)

# 2. Account (user is owner)
account =
  case Repo.one(from a in Accounts.Account, where: a.slug == ^account_slug) do
    nil ->
      {:ok, acct} = Accounts.create_account(scope, %{name: "Demo Replay", slug: account_slug})
      IO.puts("  account: created #{account_slug} (#{acct.id})")
      acct

    acct ->
      IO.puts("  account: exists #{account_slug} (#{acct.id})")
      acct
  end

# 2b. Active account preference. The API scope (from the Bearer token) reads
#     this to resolve active_account_id; without it, list_projects filters on
#     account_id: nil and Ecto raises. init_project calls /api/projects.
case UserPreferences.get_user_preference(scope) do
  {:error, :not_found} ->
    {:ok, _} = UserPreferences.create_user_preferences(scope, %{active_account_id: account.id})

  {:ok, _} ->
    {:ok, _} = UserPreferences.update_user_preferences(scope, %{active_account_id: account.id})
end

IO.puts("  preference: active_account_id=#{account.id}")

# 3. CLI OAuth application (trusted public PKCE client — empty secret)
app_id =
  case Repo.one(from a in "oauth_applications", where: a.uid == ^cli_oauth_uid, select: a.id) do
    nil ->
      {1, [%{id: id}]} =
        Repo.insert_all(
          "oauth_applications",
          [
            %{
              name: "CodeMySpec CLI",
              uid: cli_oauth_uid,
              secret: "",
              redirect_uri: "http://localhost:9876/oauth/callback",
              scopes: "",
              inserted_at: now,
              updated_at: now
            }
          ],
          returning: [:id]
        )

      IO.puts("  oauth_application: created #{cli_oauth_uid}")
      id

    id ->
      IO.puts("  oauth_application: exists #{cli_oauth_uid}")
      id
  end

# 4. Project 49d80233 (what init_project fetches). local_path is a local concern;
#    the harness sets it when init_project upserts the local copy.
project =
  case Repo.get(Project, project_id) do
    nil ->
      {:ok, p} =
        %Project{}
        |> Project.bootstrap_changeset(%{
          id: project_id,
          name: "Market My Spec",
          module_name: "MarketMySpec",
          account_id: account.id,
          status: :created
        })
        |> Repo.insert()

      IO.puts("  project: created #{p.name} (#{p.id})")
      p

    p ->
      IO.puts("  project: exists #{p.name} (#{p.id})")
      p
  end

# 5. Access token (Bearer the harness presents). Long-lived for the replay.
#    Insert directly with a self-generated token: the project's AccessToken
#    changeset references a stale :expires_at field. ex_oauth2_provider validates
#    by token lookup + (inserted_at + expires_in) expiry, so this is sufficient.
access_token =
  case Repo.one(
         from t in AccessToken,
           where:
             t.resource_owner_id == ^user.id and t.application_id == ^app_id and
               is_nil(t.revoked_at),
           order_by: [desc: t.id],
           limit: 1,
           select: t.token
       ) do
    nil ->
      tv = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      {1, _} =
        Repo.insert_all("oauth_access_tokens", [
          %{
            token: tv,
            resource_owner_id: user.id,
            application_id: app_id,
            scopes: "",
            expires_in: 31_536_000,
            previous_refresh_token: "",
            inserted_at: now,
            updated_at: now
          }
        ])

      IO.puts("  access_token: created")
      tv

    tv ->
      IO.puts("  access_token: exists")
      tv
  end

token = %{token: access_token}

IO.puts("""

=== Demo backend ready ===
email:        #{email}
account_id:   #{account.id}
project_id:   #{project.id}
ACCESS_TOKEN: #{token.token}

Next (harness side, SQLite cli_demo.db):
  CMS_OAUTH_TOKEN=#{token.token} MIX_ENV=cli_demo mix run priv/repo/cli_demo_seeds.exs
""")
