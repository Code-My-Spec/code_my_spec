defmodule CodeMySpecSpex.Story606.Criterion5514Spex do
  @moduledoc """
  Story 606 — Onboarding requires an active account.
  Criterion 5514 — Rule: Submitting the create-account form on
  /app creates the account, sets it as the user's active
  account, and advances onboarding to the next step.

  Setup: register a user with no accounts, mount onboarding (which
  shows the create-account form), submit the form with a valid name.
  Observable: the LiveView navigates away from the create-account form,
  and a fresh mount of /app now renders the next step
  (the project-name form / static onboarding content) instead of the
  account form — meaning an active account is set on scope.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Valid create-account submission advances onboarding" do
    scenario "Valid submission creates the account and advances onboarding" do
      given_ "the user is on /app with no accounts", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the user submits the create-account form with a valid name", context do
        result =
          context.view
          |> form("#account_form", account: %{name: "My Workspace"})
          |> render_submit()

        {:ok, Map.put(context, :submit_result, result)}
      end

      then_ "the submit triggers a navigation away from the create-account form", context do
        assert {:error, {kind, %{to: target}}} = context.submit_result,
               "expected a navigation after a valid create-account submission, " <>
                 "got: #{inspect(context.submit_result)}"

        assert kind in [:redirect, :live_redirect],
               "expected a redirect-style navigation, got: #{inspect(kind)}"

        assert target == "/app",
               "expected to be navigated back to /app for the next step, " <>
                 "got: #{target}"

        {:ok, context}
      end

      then_ "a fresh mount of /app shows the next step, not the account form",
            context do
        {:ok, next_view, next_html} = live(context.conn, "/app")

        refute has_element?(next_view, "form#account_form"),
               "did not expect the create-account form to re-appear after a valid submission"

        assert has_element?(next_view, "form#project_form") or
                 next_html =~ ~r/install.*claude code/i,
               "expected the next onboarding step (project-name form or static content) " <>
                 "to render once the account is created and active"

        {:ok, context}
      end
    end
  end
end
