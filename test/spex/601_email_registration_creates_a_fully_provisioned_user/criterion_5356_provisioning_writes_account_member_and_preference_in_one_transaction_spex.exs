defmodule CodeMySpecSpex.Story601.Criterion5356Spex do
  @moduledoc """
  Story 601 — Email registration creates a fully provisioned user
  Criterion 5356 — Rule: Provisioning is atomic.

  Observable through the public surface: the three rows being present
  is inferred from the user reaching /app/accounts without a picker
  redirect (same signal as 5355). The "single transaction" guarantee
  is a structural property of the implementation and would have to be
  verified by a unit test on the provisioning function itself or by a
  fault-injection harness (covered separately in criterion 5357). It
  is intentionally not asserted here.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  spex "Provisioning is atomic" do
    scenario "Provisioning writes account, member, and preference in one transaction" do
      given_ :registered_user_with_magic_link

      when_ "provisioning runs", context do
        conn = get(context.conn, context.magic_link_url)
        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the Account, Member, and UserPreference rows are all present after the next request",
            context do
        assert get_session(context.conn, :user_token),
               "expected session token after magic link click"

        accounts_conn = get(recycle(context.conn), "/app/accounts")

        assert accounts_conn.status == 200,
               "expected /app/accounts to load (200) — all three provisioning rows " <>
                 "must exist for require_active_account to pass. " <>
                 "Got status #{accounts_conn.status}."

        :ok
      end
    end
  end
end
