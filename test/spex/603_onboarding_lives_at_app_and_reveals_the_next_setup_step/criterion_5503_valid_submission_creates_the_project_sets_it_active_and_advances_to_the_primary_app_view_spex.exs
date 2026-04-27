defmodule CodeMySpecSpex.Story603.Criterion5503Spex do
  @moduledoc """
  Story 603 — Onboarding lives at /app and reveals the next setup step.
  Criterion 5503 — Rule: Submitting a valid project name creates the
  project, sets it as active, and advances to the primary app view.

  Setup: user with active account, zero projects, on /app (project-name
  step). Submits the form with a valid name. Observable: navigation
  back to /app, then a fresh mount renders the primary Overview view —
  proving both project creation and active-project selection.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Valid submission creates the project, sets it active, and advances to the primary app view" do
    scenario "Valid submission creates the project, sets it active, and advances to the primary app view" do
      given_ "the user is on /app with the project-name form", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the user submits the project-name form with a valid name", context do
        result =
          context.view
          |> form("#project_form", project: %{name: "First Project"})
          |> render_submit()

        {:ok, Map.put(context, :submit_result, result)}
      end

      then_ "the submit triggers a navigation back to /app", context do
        assert {:error, {kind, %{to: target}}} = context.submit_result,
               "expected a navigation after a valid project-name submission, " <>
                 "got: #{inspect(context.submit_result)}"

        assert kind in [:redirect, :live_redirect],
               "expected a redirect-style navigation, got: #{inspect(kind)}"

        assert target == "/app",
               "expected redirect target /app, got: #{inspect(target)}"

        {:ok, context}
      end

      then_ "a fresh mount of /app shows the primary app view, not the project form",
            context do
        {:ok, next_view, next_html} = live(context.conn, "/app")

        refute has_element?(next_view, "form#project_form"),
               "did not expect the project-name form after the project was created and set active"

        assert next_html =~ "Overview",
               "expected the Overview heading on /app once setup is complete"

        {:ok, context}
      end
    end
  end
end
