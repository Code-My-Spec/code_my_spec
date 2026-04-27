defmodule CodeMySpecSpex.Story603.Criterion5504Spex do
  @moduledoc """
  Story 603 — Onboarding lives at /app and reveals the next setup step.
  Criterion 5504 — Rule: An empty project-name submission re-renders
  the form with validation errors and does not create a project.

  Setup: user with active account, zero projects, on /app (project-name
  step). Submits the form with an empty name. Observable: no
  navigation, the project-name form is still rendered.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Empty submission re-renders the form with errors and does not create a project" do
    scenario "Empty submission re-renders the form with errors and does not create a project" do
      given_ "the user is on /app with the project-name form", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the user submits the project-name form with an empty name", context do
        result =
          context.view
          |> form("#project_form", project: %{name: ""})
          |> render_submit()

        {:ok, Map.put(context, :submit_result, result)}
      end

      then_ "the submit does not trigger a navigation", context do
        refute match?({:error, {:redirect, _}}, context.submit_result),
               "did not expect a redirect after an empty project-name submission"

        refute match?({:error, {:live_redirect, _}}, context.submit_result),
               "did not expect a live_redirect after an empty project-name submission"

        {:ok, context}
      end

      then_ "the project-name form is still rendered", context do
        assert has_element?(context.view, "form#project_form"),
               "expected the project-name form to remain rendered after an empty submission"

        {:ok, context}
      end
    end
  end
end
