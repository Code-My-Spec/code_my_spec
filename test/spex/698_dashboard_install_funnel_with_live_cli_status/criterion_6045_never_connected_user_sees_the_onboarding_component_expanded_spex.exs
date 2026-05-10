defmodule CodeMySpecSpex.Story698.Criterion6045Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6045 — Rule: The dashboard onboarding component renders
  expanded by default for users whose CLI has never joined Presence.

  Setup: a freshly-registered user with an active account but whose
  CLI has never connected. Mounts /app and asserts the onboarding card
  renders in its expanded state with three install steps and a
  "Not connected" pill.

  Surface contract assumed by this spec:
    * [data-test="onboarding-card"][data-state="expanded"]
    * [data-test="install-step-1|2|3"]
    * [data-test="cli-status-pill"] text contains "Not connected"
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Never-connected user sees the onboarding component expanded" do
    scenario "Never-connected user sees the onboarding component expanded" do
      given_ "the user is on /app and no CLI has ever joined Presence", context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the onboarding card renders in its expanded state", context do
        assert has_element?(context.view, "[data-test='onboarding-card'][data-state='expanded']"),
               "expected the onboarding card to render expanded for a never-connected user"

        {:ok, context}
      end

      then_ "the three numbered install steps are visible", context do
        for n <- 1..3 do
          assert has_element?(context.view, "[data-test='install-step-#{n}']"),
                 "expected install-step-#{n} to be visible in the expanded card"
        end

        {:ok, context}
      end

      then_ "the status pill reads Not connected", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "Not connected",
               "expected the status pill to read \"Not connected\", got: #{pill}"

        {:ok, context}
      end
    end
  end
end
