defmodule CodeMySpecSpex.Story603.Criterion5501Spex do
  @moduledoc """
  Story 603 — Onboarding lives at /app and reveals the next setup step.
  Criterion 5501 — Rule: Once the user has both an account and a first
  project, /app renders the app's primary view (the Overview).

  Setup creates an active account and a project, then mounts /app and
  asserts neither setup form is present and the Overview content is.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup %{scope: scope, account: account} do
    project = Fixtures.project_fixture(scope, account_id: account.id, name: "First Project")
    {:ok, _} = Fixtures.select_active_project(scope, project.id)
    {:ok, %{project: project}}
  end

  spex "User with an account and a project sees the primary app view on /app" do
    scenario "User with an account and a project sees the primary app view on /app" do
      given_ "the user is on /app with an active account and at least one project",
             context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "neither setup form renders", context do
        refute has_element?(context.view, "form#account_form"),
               "did not expect the create-account form once both setup steps are done"

        refute has_element?(context.view, "form#project_form"),
               "did not expect the project-name form once both setup steps are done"

        {:ok, context}
      end

      then_ "the primary app (Overview) view renders", context do
        assert context.html =~ "Overview",
               "expected the Overview heading on /app for a user who has " <>
                 "completed setup, got: #{String.slice(context.html, 0, 200)}..."

        {:ok, context}
      end
    end
  end
end
