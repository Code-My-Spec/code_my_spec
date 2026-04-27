defmodule CodeMySpecSpex.Story603.Criterion5499Spex do
  @moduledoc """
  Story 603 — Onboarding lives at /app and reveals the next setup step.
  Criterion 5499 — Rule: /app renders the create-account form (the
  first wizard step) when the user owns zero accounts.

  This criterion is a thin wrapper over story 606's account-step
  rendering, observed at /app. Story 606's spex own the deeper
  assertions on the account form's behavior; this spec confirms /app
  is the host route.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "User with no accounts sees the create-account form on /app" do
    scenario "User with no accounts sees the create-account form on /app" do
      given_ "the user is on /app with zero accounts", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the create-account form renders as the first wizard step", context do
        assert has_element?(context.view, "form#account_form"),
               "expected the create-account form on /app when the user owns zero accounts"

        {:ok, context}
      end

      then_ "the project-name form does not render yet", context do
        refute has_element?(context.view, "form#project_form"),
               "did not expect the project-name form before an account exists"

        {:ok, context}
      end
    end
  end
end
