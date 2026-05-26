defmodule CodeMySpecSpex.Story812.Criterion6536Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6536 — Rule 4 (hybrid): Register and onboarding mounts fire
  their gtag behavior events.

  Hybrid design: view_register_page, onboarding_panel_viewed, and
  install_step_copied are browser behavior events fired by gtag, not
  dispatched server-side via Analytics.dispatch/3. The relevant
  LiveViews must push a `gtag` JS command to the browser on mount
  (or via a client-side hook) rather than calling Analytics.dispatch
  in the Elixir mount/handle_event.

  Three assertions:
  1. The registration LiveView does NOT call Analytics.dispatch(:view_register_page, ...).
  2. The app overview LiveView does NOT call Analytics.dispatch for
     :onboarding_panel_viewed or :install_step_copied.
  3. The JS layer (app.js or a LiveView hook) contains gtag calls for
     these events — confirming the browser-side path exists.

  Codebase-grep pattern. Fails if old server-side dispatch calls remain
  or if the gtag calls are absent from the JS layer.
  """

  use CodeMySpecSpex.Case

  @registration_live_path "lib/code_my_spec_web/live/user_live/registration.ex"
  @overview_live_path "lib/code_my_spec_web/live/app_live/overview.ex"

  spex "Register and onboarding mounts fire their gtag behavior events" do
    scenario "registration LiveView does not dispatch view_register_page server-side" do
      given_ "the registration LiveView source", context do
        content = File.read!(@registration_live_path)
        {:ok, Map.put(context, :source, content)}
      end

      when_ "we scan for server-side dispatch of view_register_page", context do
        {:ok, context}
      end

      then_ "no Analytics.dispatch(:view_register_page, ...) call remains", context do
        refute context.source =~ ~r/Analytics\.dispatch\(\s*:view_register_page/,
               """
               Registration LiveView still calls Analytics.dispatch(:view_register_page, ...) server-side.
               In the hybrid design this event is a gtag browser event — remove the Analytics.dispatch call.
               """

        {:ok, context}
      end
    end

    scenario "app overview LiveView does not dispatch onboarding_panel_viewed or install_step_copied server-side" do
      given_ "the app overview LiveView source", context do
        content = File.read!(@overview_live_path)
        {:ok, Map.put(context, :source, content)}
      end

      when_ "we scan for server-side dispatch of the two onboarding behavior events", context do
        {:ok, context}
      end

      then_ "no Analytics.dispatch(:onboarding_panel_viewed, ...) call remains", context do
        refute context.source =~ ~r/Analytics\.dispatch\(\s*:onboarding_panel_viewed/,
               """
               App overview LiveView still calls Analytics.dispatch(:onboarding_panel_viewed, ...) server-side.
               In the hybrid design this event is a gtag browser event — remove the Analytics.dispatch call.
               """

        {:ok, context}
      end

      then_ "no Analytics.dispatch(:install_step_copied, ...) call remains", context do
        refute context.source =~ ~r/Analytics\.dispatch\(\s*:install_step_copied/,
               """
               App overview LiveView still calls Analytics.dispatch(:install_step_copied, ...) server-side.
               In the hybrid design this event is a gtag browser event — remove the Analytics.dispatch call.
               """

        {:ok, context}
      end
    end

    scenario "the registration LiveView colocated hook fires gtag for view_register_page" do
      given_ "the registration LiveView source", context do
        content = File.read!(@registration_live_path)
        {:ok, Map.put(context, :source, content)}
      end

      when_ "we scan for gtag('event', 'view_register_page', ...) in the colocated hook", context do
        {:ok, context}
      end

      then_ "the .ViewRegisterPage hook calls gtag for view_register_page on mount", context do
        assert context.source =~ ~r/gtag\(\s*['"]event['"]\s*,\s*['"]view_register_page['"]/,
               "expected the .ViewRegisterPage colocated hook in registration.ex to call gtag('event', 'view_register_page', ...) on mount"

        {:ok, context}
      end
    end

    scenario "the app overview LiveView colocated hook fires gtag for onboarding and install events" do
      given_ "the app overview LiveView source", context do
        content = File.read!(@overview_live_path)
        {:ok, Map.put(context, :source, content)}
      end

      when_ "we scan for gtag calls for the onboarding behavior events", context do
        {:ok, context}
      end

      then_ "the .SignUpTracking hook calls gtag for onboarding_panel_viewed on mount", context do
        assert context.source =~ ~r/gtag\(\s*['"]event['"]\s*,\s*['"]onboarding_panel_viewed['"]/,
               "expected the .SignUpTracking colocated hook in overview.ex to call gtag('event', 'onboarding_panel_viewed', ...) on mount"

        {:ok, context}
      end

      then_ "the .SignUpTracking hook calls gtag for install_step_copied on step copy", context do
        assert context.source =~ ~r/gtag\(\s*['"]event['"]\s*,\s*['"]install_step_copied['"]/,
               "expected the .SignUpTracking colocated hook in overview.ex to call gtag('event', 'install_step_copied', ...) on step copy"

        {:ok, context}
      end
    end
  end
end
