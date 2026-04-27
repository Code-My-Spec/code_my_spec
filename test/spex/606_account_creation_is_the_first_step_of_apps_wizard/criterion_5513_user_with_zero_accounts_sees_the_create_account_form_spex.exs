defmodule CodeMySpecSpex.Story606.Criterion5513Spex do
  @moduledoc """
  Story 606 — Onboarding requires an active account.
  Criterion 5513 — Rule: On /app, the create-account form
  renders only for users who own zero accounts.

  Setup: register and log in a fresh user with no account memberships.
  The LiveView mount should detect `scope.active_account == nil` plus
  zero accounts in `Accounts.list_accounts/1` and render the
  create-account form as the first onboarding step.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Zero-account user sees the create-account form on /app" do
    scenario "User with zero accounts sees the create-account form" do
      given_ "the user is on /app with no accounts", context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the create-account form renders", context do
        assert has_element?(context.view, "form#account_form"),
               "expected a create-account form on /app when the " <>
                 "user owns zero accounts"

        {:ok, context}
      end

      then_ "the form has a name input the user can fill in", context do
        assert has_element?(context.view, "input[name='account[name]']"),
               "expected an account name text input inside the create-account form"

        {:ok, context}
      end

      then_ "the project-name form does NOT render", context do
        refute has_element?(context.view, "form#project_form"),
               "did not expect the project-name form before the user has an active account"

        {:ok, context}
      end
    end
  end
end
