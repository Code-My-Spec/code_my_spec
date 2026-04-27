defmodule CodeMySpecSpex.Story606.Criterion5516Spex do
  @moduledoc """
  Story 606 — Onboarding requires an active account.
  Criterion 5516 — Rule: Submitting an invalid create-account form
  re-renders the form with validation errors. The user remains on the
  first onboarding step (no navigation) and no account is created.

  Setup: register a user with no accounts, mount onboarding, submit the
  create-account form with a blank name (fails the changeset's
  required-name validation). Observable: the LiveView stays put, the
  account form is still present, and the next-step content (project
  form) is NOT rendered.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Invalid create-account submission keeps the user on the first step" do
    scenario "Invalid submission re-renders the form with errors" do
      given_ "the user is on /app with no accounts", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the user submits the create-account form with a blank name", context do
        result =
          context.view
          |> form("#account_form", account: %{name: ""})
          |> render_submit()

        {:ok, Map.put(context, :submit_result, result)}
      end

      then_ "the submit does not trigger a navigation", context do
        refute match?({:error, {:redirect, _}}, context.submit_result),
               "did not expect a navigation after an invalid create-account submission"

        refute match?({:error, {:live_redirect, _}}, context.submit_result),
               "did not expect a live_redirect after an invalid create-account submission"

        {:ok, context}
      end

      then_ "the create-account form is still rendered", context do
        assert has_element?(context.view, "form#account_form"),
               "expected the create-account form to remain rendered after an invalid submission"

        {:ok, context}
      end

      then_ "the next-step content is not rendered yet", context do
        refute has_element?(context.view, "form#project_form"),
               "did not expect the project-name form before a valid account is created"

        {:ok, context}
      end
    end
  end
end
