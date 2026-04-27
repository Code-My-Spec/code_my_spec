defmodule CodeMySpecSpex.Story603.Criterion5500Spex do
  @moduledoc """
  Story 603 — Onboarding lives at /app and reveals the next setup step.
  Criterion 5500 — Rule: /app renders the next missing setup step.

  When the user has an active account but zero projects, /app renders
  the project-name form as the next onboarding step. The create-account
  form is gone (account already done) and the primary app view is not
  yet rendered (project step is not done).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "User with an account but no projects sees the project-name form on /app" do
    scenario "User with an account but no projects sees the project-name form on /app" do
      given_ "the user is on /app with an active account and zero projects", context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the project-name form renders", context do
        assert has_element?(context.view, "form#project_form"),
               "expected the project-name form on /app when the user has an " <>
                 "active account but zero projects"

        {:ok, context}
      end

      then_ "the create-account form does not render", context do
        refute has_element?(context.view, "form#account_form"),
               "did not expect the create-account form when the user already has an active account"

        {:ok, context}
      end
    end
  end
end
