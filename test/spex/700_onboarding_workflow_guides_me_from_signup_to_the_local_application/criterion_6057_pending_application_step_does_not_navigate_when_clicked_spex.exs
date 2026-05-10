defmodule CodeMySpecSpex.Story700.Criterion6057Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6057 — Rule: A pending (not-yet-reached) step is
  non-actionable — its form is not submittable, its link is not
  clickable, and it does not respond to user input.

  When the application step is pending (account not yet done), it
  must render as a non-clickable tile — no `href` to the local
  workspace.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Pending application step has no navigation affordance" do
    scenario "Pending application step does not navigate when clicked" do
      given_ "the user is on /app with no account", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the application rung is in the pending state", context do
        assert has_element?(
                 context.view,
                 "[data-test='application-rung'][data-state='pending']"
               ),
               "expected application-rung in 'pending' state when prerequisites are not met"

        {:ok, context}
      end

      then_ "the pending application rung does not carry a clickable href", context do
        # Anchor: the rung itself is rendered.
        assert has_element?(context.view, "[data-test='application-rung']")

        rendered = element(context.view, "[data-test='application-rung']") |> render()

        refute rendered =~ ~s|href="http://localhost:4003"|,
               "did not expect the pending application tile to link to the local workspace; got: #{rendered}"

        {:ok, context}
      end
    end
  end
end
