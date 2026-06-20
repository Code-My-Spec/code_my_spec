defmodule CodeMySpecSpex.Story812.Criterion6536Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6536 — Rule 4 (hybrid): Register and onboarding mounts fire
  their gtag behavior events.

  Hybrid design: view_register_page, onboarding_panel_viewed, and
  install_step_copied are browser behavior events fired by gtag colocated
  hooks — not dispatched server-side via Analytics.dispatch/3. The surface
  contract this spec guards:

  1. The registration LiveView renders with its `.ViewRegisterPage` gtag
     hook attached, so `view_register_page` fires on mount.
  2. The app overview LiveView renders with its `.SignUpTracking` gtag
     hook attached, so `onboarding_panel_viewed` fires on mount.
  3. Copying an install step pushes `install_step_copied` from the server
     to the browser, where the `.SignUpTracking` hook forwards it to gtag.

  Driven through the LiveView surface — the hooks render into the DOM the
  browser receives, and the step-copy event is pushed by the server. The
  gtag call itself is browser JS, exercised by browser QA. Fails if a hook
  stops rendering or the server stops pushing the step-copy event.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "Register and onboarding mounts fire their gtag behavior events" do
    scenario "the registration page wires the ViewRegisterPage gtag hook on mount" do
      given_ "an unauthenticated visitor", context do
        {:ok, context}
      end

      when_ "the registration page is rendered", context do
        {:ok, _lv, html} = live(context.conn, "/users/register")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the page carries the .ViewRegisterPage colocated hook", context do
        assert context.html =~ "phx-hook=",
               "expected the registration page to attach a colocated hook"

        assert context.html =~ "ViewRegisterPage",
               "expected the registration page to wire the .ViewRegisterPage gtag hook (fires view_register_page on mount)"

        {:ok, context}
      end
    end

    scenario "the app overview wires the SignUpTracking gtag hook on mount" do
      given_ "a logged-in user", context do
        user = CodeMySpecSpex.Fixtures.user_fixture()
        {:ok, Map.put(context, :conn, log_in_user(context.conn, user))}
      end

      when_ "the app overview is rendered", context do
        {:ok, _lv, html} = live(context.conn, "/app")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the page carries the .SignUpTracking colocated hook", context do
        assert context.html =~ "phx-hook=",
               "expected the app overview to attach a colocated hook"

        assert context.html =~ "SignUpTracking",
               "expected the app overview to wire the .SignUpTracking gtag hook (fires onboarding_panel_viewed on mount)"

        {:ok, context}
      end
    end

    scenario "copying an install step pushes install_step_copied to the browser" do
      given_ "a logged-in user on the app overview", context do
        user = CodeMySpecSpex.Fixtures.user_fixture()
        conn = log_in_user(context.conn, user)
        {:ok, lv, _html} = live(conn, "/app")
        {:ok, Map.put(context, :lv, lv)}
      end

      when_ "an install step is copied", context do
        render_hook(context.lv, "copy_step", %{"step" => "1"})
        {:ok, context}
      end

      then_ "the server pushes install_step_copied for the gtag hook to forward", context do
        assert_push_event(context.lv, "install_step_copied", %{step: 1})
        {:ok, context}
      end
    end
  end
end
