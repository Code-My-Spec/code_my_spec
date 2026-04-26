defmodule CodeMySpecSpex.Story601.Criterion5355Spex do
  @moduledoc """
  Story 601 — Email registration creates a fully provisioned user
  Criterion 5355 — Rule: Successful auth leaves the user fully
  provisioned: a personal Account exists, the user is its owner via
  Member, and a UserPreference row points active_account_id at that
  account.

  Setup uses the public registration LiveView. We observe full
  provisioning through the public surface: reaching the
  account-gated /app/accounts route succeeds only when Account,
  Member, and UserPreference all exist (require_active_account would
  otherwise redirect to /app/accounts/picker).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  spex "Successful auth leaves user fully provisioned" do
    scenario "First magic link click provisions account, owner membership, and active-account preference" do
      given_ :registered_user_with_magic_link

      when_ "the magic link controller completes", context do
        conn = get(context.conn, context.magic_link_url)
        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "a personal Account exists for the user", context do
        assert get_session(context.conn, :user_token),
               "expected session token after magic link — prerequisite for provisioning check"

        accounts_conn = get(recycle(context.conn), "/app/accounts")

        assert accounts_conn.status == 200,
               "expected /app/accounts to load (200) — personal Account, Member, " <>
                 "and UserPreference must all exist for require_active_account to pass. " <>
                 "Got status #{accounts_conn.status}."

        :ok
      end

      then_ "scope.active_account is non-nil on the next request", context do
        accounts_conn = get(recycle(context.conn), "/app/accounts")

        assert accounts_conn.status == 200,
               "expected accounts page to load (active_account is set), " <>
                 "got status #{accounts_conn.status}"

        :ok
      end
    end
  end
end
