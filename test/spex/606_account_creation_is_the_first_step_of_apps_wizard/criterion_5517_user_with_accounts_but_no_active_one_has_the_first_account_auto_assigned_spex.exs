defmodule CodeMySpecSpex.Story606.Criterion5517Spex do
  @moduledoc """
  Story 606 — Onboarding requires an active account.
  Criterion 5517 — Rule: Users who own at least one account proceed to
  the next onboarding step, with their first account auto-assigned as
  active if no active account is set on the scope.

  Setup: register the user, fixture an owned account, but DO NOT call
  select_active_account. The LiveView mount should detect
  `scope.active_account == nil` plus a non-empty account list, select
  the first account as active, rebuild the scope, and render the next
  onboarding step (project form) without showing the create-account form.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  setup %{user: user} do
    account = Fixtures.account_with_owner_fixture(user, %{name: "First Workspace"})
    {:ok, %{first_account: account}}
  end

  spex "User with accounts but no active selection is auto-assigned the first" do
    scenario "User with accounts but no active one has the first account auto-assigned" do
      given_ "the user is on /app with accounts but no active selection", context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the create-account form does NOT render", context do
        refute has_element?(context.view, "form#account_form"),
               "did not expect the create-account form when the user already owns at least one account"

        {:ok, context}
      end

      then_ "the next onboarding step renders", context do
        assert has_element?(context.view, "form#project_form") or
                 context.html =~ ~r/install.*claude code/i,
               "expected the next onboarding step (project-name form or static onboarding content) " <>
                 "to render once an account is auto-assigned"

        {:ok, context}
      end
    end
  end
end
