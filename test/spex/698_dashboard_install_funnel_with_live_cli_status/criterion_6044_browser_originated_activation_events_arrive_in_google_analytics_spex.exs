defmodule CodeMySpecSpex.Story698.Criterion6044Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6044 — Rule: Activation events reach Google Analytics,
  including browser-originated events.

  Browser-side events (onboarding_panel_viewed, install_step_copied)
  are forwarded to GA via gtag. The LiveView pushes these events to
  the client over the channel; the client-side hook calls
  `gtag('event', name, params)`. The contract this spec enforces is
  the LiveView push — the actual gtag call happens in JS and is not
  testable from a server-side spec.

  Surface contract:
    * `Phoenix.LiveViewTest.assert_push_event/3` captures the
      `analytics` push from the LiveView with `name` and `params` keys
      that the JS hook forwards to gtag.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Browser-originated activation events are pushed to the client for GA forwarding" do
    scenario "Browser-originated activation events arrive in Google Analytics" do
      given_ "the user mounts /app", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "an analytics push for onboarding_panel_viewed is sent to the client", context do
        user_id = context.user.id

        assert_push_event(context.view, "analytics", %{
          name: "onboarding_panel_viewed",
          params: %{user_id: ^user_id}
        })

        {:ok, context}
      end

      when_ "the user clicks the copy button on step 1", context do
        context.view
        |> element("[data-test='copy-step-1']")
        |> render_click()

        {:ok, context}
      end

      then_ "an analytics push for install_step_copied is sent to the client", context do
        user_id = context.user.id

        assert_push_event(context.view, "analytics", %{
          name: "install_step_copied",
          params: %{user_id: ^user_id, step: 1}
        })

        {:ok, context}
      end
    end
  end
end
