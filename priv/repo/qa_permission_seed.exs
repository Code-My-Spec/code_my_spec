# QA Permission Owner Seed — sign in as a project's own account owner
#
# Usage: mix cms.seed priv/repo/qa_permission_seed.exs
#
# ## What this is for
#
# A `tap_out` (or any) MCP call made through the local harness proxy
# authenticates via the project's deploy key, which `DeployKeyOrOAuth`
# deliberately resolves to the project's real account owner -- its own
# moduledoc: "on their project it is their decision to make." So a
# `PermissionRequest` raised that way is owned by that real user, and
# `PermissionLive.Show` (`/app/permissions/:id`) refuses anyone else. QA has
# no password for that account, and should not be given one (issue
# a0880cf1; John, 2026-10-13: "Owner login is just a fixture problem. Just
# make a seed for this.").
#
# This mints that owner a real login token -- the same mechanism
# `CodeMySpecWeb.DevSignInController` uses for an account whose password IS
# known -- and prints the URL. No password, no real credential leaves this
# script: it mints one single-use login token, scoped to this one owner,
# the same way any "forgot your password" email would.
#
# Idempotent. Re-run it for a fresh token whenever the last one is spent or
# expired.

import Ecto.Query

alias CodeMySpec.Accounts
alias CodeMySpec.Users

# Math Test Project's own account (priv/repo/seeds/math_test_project.exs).
# The same fixture `qa_wake_seed.exs` and the QA plan's "agent sandbox"
# section already document -- this is the project a locally-raised
# tap_out's PermissionRequest ends up owned by.
math_test_project_account_id = "0f27281c-240b-4d6d-8e52-9c5972329522"

owner = Accounts.get_account_owner(math_test_project_account_id)

if is_nil(owner) do
  Mix.raise("""
  No owner found for account #{math_test_project_account_id} (Math Test
  Project). Run `mix run priv/repo/seeds/math_test_project.exs` first, and
  make sure that account has a member with role: :owner.
  """)
end

encoded_token = Users.mint_login_token(owner)
sign_in_url = "http://localhost:4000/users/log-in/#{encoded_token}"

IO.puts("""
Minted a one-time sign-in link for Math Test Project's own account owner.

Owner:        #{owner.email} (user id #{owner.id})
Sign-in URL:  #{sign_in_url}

A locally-raised tap_out's PermissionRequest is owned by this user --
DeployKeyOrOAuth resolves the project's deploy key to its account owner.
Open the URL in the QA browser session to sign in as that owner, then visit
/app/permissions/:id to approve or deny the request.

Single-use and short-lived, like any login token. Re-run this seed for a
fresh one if it expires or is already spent.
""")
