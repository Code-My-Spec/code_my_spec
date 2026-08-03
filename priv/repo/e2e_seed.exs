# Seeds the end-to-end database with the one thing a harness needs to connect:
# an account, a project, and that project's deploy key.
#
# Run against the CMS_E2E database only. Prints the project id and deploy key so
# the harness can be pointed at them.
#
#     CMS_E2E=1 CMS_E2E_SEED=1 MIX_ENV=test elixir -S mix run priv/repo/e2e_seed.exs
#
# CMS_E2E_SEED=1 keeps this from trying to bind 4102, so it can be run while
# the server it seeds for is already up. Note it ROTATES the deploy key on
# every run — an older key stops working, which shows up as a 403 on the
# websocket upgrade and a 401 on the token exchange.

alias CodeMySpec.Accounts
alias CodeMySpec.Projects
alias CodeMySpec.Repo
alias CodeMySpec.Users
alias CodeMySpec.Users.Scope

email = "e2e-harness@example.com"

user =
  case Users.get_user_by_email(email) do
    nil ->
      {:ok, user} = Users.register_user(%{email: email})
      user

    user ->
      user
  end

scope = Scope.for_user(user)

account =
  case Accounts.list_accounts(scope) do
    [account | _] ->
      account

    [] ->
      {:ok, account} = Accounts.create_account(scope, %{name: "E2E", slug: "e2e"})

      account
  end

# The scope's account has to be the one we just made, or project creation writes
# against whatever preference the user happens to carry.
scope = %Scope{scope | active_account: account, active_account_id: account.id}

project =
  case Projects.list_projects(scope) do
    [project | _] ->
      project

    [] ->
      {:ok, project} =
        Projects.create_project(scope, %{name: "e2e-todo", module_name: "E2eTodo"})

      project
  end

# Same shape the project form generates: 64 random bytes, hex. The column is
# encrypted and matched by a blind-index hash, so the plaintext exists only here
# and in whatever the harness is handed.
deploy_key = :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)

{:ok, project} = Projects.update_project(scope, project, %{deploy_key: deploy_key})

IO.puts("""

CMS_PROJECT_ID=#{project.id}
CMS_DEPLOY_KEY=#{deploy_key}
CMS_SERVER_URL=ws://127.0.0.1:4102/socket/websocket
""")

_ = Repo
