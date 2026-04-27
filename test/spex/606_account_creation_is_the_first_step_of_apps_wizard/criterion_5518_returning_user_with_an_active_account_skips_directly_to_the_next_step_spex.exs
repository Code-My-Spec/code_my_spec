defmodule CodeMySpecSpex.Story606.Criterion5518Spex do
  @moduledoc """
  Story 606 — Onboarding requires an active account.
  Criterion 5518 — Rule: Users who already have an active account skip
  directly to the next onboarding step.

  Setup: register, log in, create an account, and select it as active.
  The LiveView mount should bypass account-creation entirely and render
  the existing project-name onboarding flow.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Returning user with an active account skips the create-account step" do
    scenario "Returning user with an active account skips directly to the next step" do
      given_ "the user is on /app with an active account", context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the create-account form does NOT render", context do
        refute has_element?(context.view, "form#account_form"),
               "did not expect the create-account form when the user already has an active account selected"

        {:ok, context}
      end

      then_ "the next onboarding step renders", context do
        assert has_element?(context.view, "form#project_form") or
                 context.html =~ ~r/install.*claude code/i,
               "expected the next onboarding step to render for a returning user with an active account"

        {:ok, context}
      end
    end
  end
end
