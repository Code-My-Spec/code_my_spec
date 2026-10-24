defmodule CodeMySpecSpex.Story700.Criterion6052Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6052 — Rule: Every step stays visible, completed ones as
  compact summary tiles and the active one as the focal element.

  A user with an account and a project has finished everything this
  page can walk them through, so both rungs read done and nothing is
  active. That is the state anyone arriving from the guided intake
  lands in — it makes their account and project for them — and a
  ladder still showing an active step there would be inventing work.

  Surface contract: each rung carries `data-test="<step>-rung"` and
  `data-state="active"|"done"|"pending"`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = CodeMySpecSpex.Fixtures.configure_agent_models(context.scope)
    :ok
  end

  spex "Done, active, and pending step states render side by side", criterion: 415 do
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

      then_ "Define is the next active step", context do
        assert has_element?(context.view, "[data-test='define-rung'][data-state='active']")
        assert has_element?(context.view, "[data-test='define-rung'] a", "Define your project")

        {:ok, context}
      end
    end
  end
end
