# Mint a deploy key for a project that has none.
#
#     MIX_ENV=dev elixir -S mix run --no-start scripts/mint_deploy_key.exs <project-id>
#
# The project form has a Generate button and that is the customer-facing path.
# This exists for the case the form cannot serve: an operator onboarding a
# checkout for a project created before keys were minted at creation (or
# imported by `CodeMySpec.Migration`, which does not mint one either).
# `CmsHarness.Credentials` cannot serve a working copy without one, so
# onboarding such a project stops here until it exists.
#
# It does not print the key, on purpose: `mix cms.harness.onboard` reads it out
# of the database, so nothing needs it on a screen or in a scrollback.
#
# `--no-start` is load-bearing. Booting the app would start
# `CodeMySpecWeb.Endpoint` and die on `:eaddrinuse` against whatever already
# holds :4000 — the same reason `Mix.Tasks.Cms.Harness.Onboard.start_local_repo/0`
# starts exactly `Vault` and `Repo` and nothing else.
#
# Goes through `Projects.update_project/3` rather than SQL so the changeset
# computes `deploy_key_hash` and the encrypted column is written by `Vault` —
# a hand-written UPDATE gets both wrong and the failure surfaces as a refused
# channel join much later.

require Logger

project_id =
  case System.argv() do
    [id] ->
      id

    _ ->
      IO.puts(:stderr, "usage: mix run --no-start scripts/mint_deploy_key.exs <project-id>")
      System.halt(1)
  end

Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:cloak)
{:ok, _} = CodeMySpec.Vault.start_link([])
{:ok, _} = CodeMySpec.Repo.start_link([])
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: CodeMySpec.PubSub)

alias CodeMySpec.Accounts
alias CodeMySpec.Accounts.Account
alias CodeMySpec.Projects
alias CodeMySpec.Projects.Project
alias CodeMySpec.Repo
alias CodeMySpec.Users.Scope
alias CodeMySpec.Users.User

project = Repo.get!(Project, project_id)
account = Repo.get!(Account, project.account_id)

# The account's owner, because `update_project/3` asserts the project belongs to
# `scope.active_account_id` and `broadcast/2` addresses `scope.user.id`.
user =
  case Accounts.get_account_owner(account.id) do
    %User{} = user ->
      user

    nil ->
      IO.puts(:stderr, "#{account.name} has no owner — nobody to mint this as.")
      System.halt(1)
  end

scope = %Scope{
  user: user,
  user_id: user.id,
  active_account: account,
  active_account_id: account.id,
  active_project: project,
  active_project_id: project.id
}

if project.deploy_key do
  IO.puts("#{project.name} already has a deploy key — nothing to do.")
else
  case Projects.ensure_deploy_key(scope, project) do
    {:ok, updated} ->
      IO.puts("Minted a deploy key for #{updated.name} (#{updated.id}).")
      IO.puts("It is now in the database; onboarding reads it from there.")

    {:error, reason} ->
      IO.puts(:stderr, "Refused: #{inspect(reason)}")
      System.halt(1)
  end
end
