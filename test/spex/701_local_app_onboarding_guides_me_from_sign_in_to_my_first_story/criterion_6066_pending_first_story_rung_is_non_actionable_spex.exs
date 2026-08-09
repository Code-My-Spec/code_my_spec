defmodule CodeMySpecSpex.Story701.Criterion6066Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6066 — Rule: Pending rungs are non-actionable.

  Verified on the first-story rung — when init has not been run yet,
  the first-story rung renders as a pending tile with no clickable
  affordance to start the story interview.
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

  spex "Pending first-story rung is not actionable" do
    scenario "Pending first-story rung is non-actionable" do
      given_ "the user has a project but init has not been run", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the first-story rung is in the pending state", context do
        assert has_element?(
                 context.view,
                 "[data-test='first-story-rung'][data-state='pending']"
               ),
               "expected first-story-rung in 'pending' state when init is not yet done"

        {:ok, context}
      end

      then_ "the pending first-story rung has no clickable interview affordance", context do
        # Anchor: rung is rendered.
        assert has_element?(context.view, "[data-test='first-story-rung']")

        rendered = element(context.view, "[data-test='first-story-rung']") |> render()

        refute rendered =~ "phx-click",
               "did not expect a phx-click handler on the pending first-story rung; got: #{rendered}"

        refute rendered =~ ~s|href=|,
               "did not expect an href on the pending first-story rung; got: #{rendered}"

        {:ok, context}
      end
    end
  end
end
