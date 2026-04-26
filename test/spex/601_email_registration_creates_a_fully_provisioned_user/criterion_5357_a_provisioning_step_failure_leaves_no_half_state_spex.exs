defmodule CodeMySpecSpex.Story601.Criterion5357Spex do
  @moduledoc """
  Story 601 — Email registration creates a fully provisioned user
  Criterion 5357 — Rule: Provisioning is atomic (failure path).

  Target behavior: if the UserPreference insert fails, the entire
  provisioning transaction rolls back — no Account or Member row is
  left behind, and the user sees an error rather than a
  partially-provisioned state.

  This scenario requires a fault-injection harness: a test-only
  mechanism that makes UserPreference.create/insert return {:error, _}
  after the Account + Member rows have been inserted, so we can verify
  the rollback fires.

  No such harness exists yet. The entire scenario is @tag :pending with
  a documented blocker. Do not implement a stub or paper over it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint
  @moduletag :pending

  spex "Provisioning is atomic" do
    scenario "A provisioning step failure leaves no half-state" do
      # BLOCKER: requires fault-injection harness for the UserPreference insert.
      #
      # To un-pending this scenario, add one of:
      #   (a) A test-only env flag (e.g. Application.put_env(:code_my_spec,
      #       :fail_user_preference_insert, true)) that makes the provisioning
      #       function's UserPreference step return {:error, changeset}, then
      #       assert the Ecto.Multi rollback fires and no Account/Member rows
      #       survive (observable via subsequent 401/picker redirect).
      #   (b) A process-dictionary override in test support that intercepts
      #       the Ecto.Multi and raises after the Member step.
      #
      # See: test/support/atomicity_helper.ex (does not exist yet).
      #
      # Steps when unblocked:
      #
      #   given_ :registered_user_with_magic_link
      #     — drives /users/register LiveView, captures email, extracts URL
      #
      #   given_ "the UserPreference insert is configured to fail"
      #     — inject fault via the harness above
      #
      #   when_ "provisioning runs"
      #     — get(conn, "/users/log-in/#{token}")
      #
      #   then_ "no Account is left behind for that user"
      #     — attempt authenticated request; redirect to picker means no account
      #
      #   then_ "no Member row is left behind for that user"
      #     — same signal (picker redirect implies no membership either)
      #
      #   then_ "the user sees an error rather than a partially-provisioned state"
      #     — assert flash :error is present on the redirected page
      :ok
    end
  end
end
