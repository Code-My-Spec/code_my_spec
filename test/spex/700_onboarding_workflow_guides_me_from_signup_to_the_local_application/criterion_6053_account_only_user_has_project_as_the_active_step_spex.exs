defmodule CodeMySpecSpex.Story700.Criterion6053Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6053 — Rule: Exactly one step is in the active state at
  a time — it is always the first incomplete step in the fixed order.

  A user with an active account but no project has project as the
  active rung; account is done; plugin and application are pending.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "First incomplete step is the unique active step (account-only user)" do
    scenario "Account-only user has project as the active step" do
      given_ "the user has an active account but no project and no CLI history", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the project rung is the active focal element", context do
        assert has_element?(context.view, "[data-test='project-rung'][data-state='active']"),
               "expected project-rung as the active step for a user with an account but no project"

        {:ok, context}
      end

      then_ "the account rung is in the done state", context do
        assert has_element?(context.view, "[data-test='account-rung'][data-state='done']"),
               "expected account-rung in 'done' state"

        {:ok, context}
      end

      # The ladder ends at a project. The plugin and application rungs were
      # removed because neither could be cleared from this page: a plugin
      # installed on another machine, and a local app signed into somewhere
      # this server cannot see, both left a working setup looking unfinished.
      then_ "nothing is claimed about steps this page cannot see", context do
        refute has_element?(context.view, "[data-test='plugin-rung']"),
               "the plugin rung is gone — whether a plugin connected here says " <>
                 "nothing about whether Sam has one"

        refute has_element?(context.view, "[data-test='application-rung']"),
               "the application rung is gone — signing in to the local app happens " <>
                 "somewhere this page cannot observe"

        {:ok, context}
      end

      then_ "no other rung is in the active state", context do
        for rung <- ~w(account-rung plugin-rung application-rung) do
          refute has_element?(context.view, "[data-test='#{rung}'][data-state='active']"),
                 "did not expect #{rung} in 'active' state — only project should be active"
        end

        # Anchor: project IS active so the refutes above are meaningful.
        assert has_element?(context.view, "[data-test='project-rung'][data-state='active']")

        {:ok, context}
      end
    end
  end
end
