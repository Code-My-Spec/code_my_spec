defmodule CodeMySpecSpex.Story701.Criterion6065Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6065 — Rule: Within either ladder, the active rung is the
  first incomplete one in the fixed order; rungs ahead of the active
  one are pending and non-actionable; rungs behind are done.

  Verified on the per-project ladder by satisfying the init step
  (via Init agent task evaluation) and asserting project-setup is
  the active rung while first-story is pending.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_and_log_in_user

  setup context do
    _client_user = Fixtures.client_user_fixture(context.user)
    :ok
  end

  setup :setup_active_account
  setup :setup_active_project

  setup context do
    # Drive the Init agent task to "complete" through its real surface
    # — write the artifacts the InitChecker looks for into the project's
    # working directory (memfs). The setup helper Fixtures.satisfy_init/1
    # captures whatever the checker's done-predicate requires.
    :ok = Fixtures.satisfy_init(context.scope)
    :ok
  end

  spex "Active rung is the first incomplete in order" do
    scenario "Active rung is the first incomplete in order (per-project ladder)" do
      given_ "init has been run but project setup has not", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the project-setup rung is the active focal element", context do
        assert has_element?(
                 context.view,
                 "[data-test='project-setup-rung'][data-state='active']"
               ),
               "expected project-setup-rung in 'active' state once init is done"

        {:ok, context}
      end

      then_ "the init rung is in the done state", context do
        assert has_element?(context.view, "[data-test='init-rung'][data-state='done']"),
               "expected init-rung in 'done' state"

        {:ok, context}
      end

      then_ "the first-story rung is in the pending state", context do
        assert has_element?(
                 context.view,
                 "[data-test='first-story-rung'][data-state='pending']"
               ),
               "expected first-story-rung in 'pending' state until project setup is done"

        {:ok, context}
      end
    end
  end
end
