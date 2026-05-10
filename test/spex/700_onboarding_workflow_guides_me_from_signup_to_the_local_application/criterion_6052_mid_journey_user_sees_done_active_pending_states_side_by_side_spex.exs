defmodule CodeMySpecSpex.Story700.Criterion6052Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6052 — Rule: All four steps are visible at all times —
  completed steps as compact summary tiles, the active step as the
  focal expanded element, and not-yet-reached steps as dimmed/disabled
  tiles.

  A user with an active account and a project but no CLI history
  must see the account and project rungs in their done state, the
  plugin rung in its active state, and the application rung in its
  pending state — all in one render.

  Surface contract: each rung carries `data-test="<step>-rung"` and
  `data-state="active"|"done"|"pending"`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Done, active, and pending step states render side by side" do
    scenario "Mid-journey user sees done + active + pending states side by side" do
      given_ "the user has an active account and a project but never connected a CLI",
             context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the account rung is in the done state", context do
        assert has_element?(context.view, "[data-test='account-rung'][data-state='done']"),
               "expected account-rung in 'done' state for a user with an active account"

        {:ok, context}
      end

      then_ "the project rung is in the done state", context do
        assert has_element?(context.view, "[data-test='project-rung'][data-state='done']"),
               "expected project-rung in 'done' state for a user with an active project"

        {:ok, context}
      end

      then_ "the plugin rung is in the active state", context do
        assert has_element?(context.view, "[data-test='plugin-rung'][data-state='active']"),
               "expected plugin-rung in 'active' state for a never-connected user with project"

        {:ok, context}
      end

      then_ "the application rung is in the pending state", context do
        assert has_element?(
                 context.view,
                 "[data-test='application-rung'][data-state='pending']"
               ),
               "expected application-rung in 'pending' state until the CLI has connected"

        {:ok, context}
      end
    end
  end
end
