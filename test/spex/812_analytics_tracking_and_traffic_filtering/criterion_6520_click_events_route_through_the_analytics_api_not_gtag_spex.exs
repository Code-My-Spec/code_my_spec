defmodule CodeMySpecSpex.Story812.Criterion6520Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6520 — Rule 6: Click events route through the analytics
  API, not gtag.

  Codebase-grep assertion (no cassette): inspect app.js to confirm
  click events POST to `/api/browser/analytics/event` and never call
  `gtag('event', ...)`. The browser-API → server → MP path replaces
  any direct gtag call.

  Driving spec — will FAIL until app.js drops every gtag('event', ...)
  call. Pairs with 6517 (no gtag.js script) and 6518 (no
  GA_MEASUREMENT_ID).
  """

  use CodeMySpecSpex.Case

  @app_js_path "assets/js/app.js"

  spex "Click events route through the analytics API, not gtag" do
    scenario "app.js POSTs to /api/browser/analytics/event and has no gtag(...) calls" do
      given_ "the shipped browser bundle", context do
        {:ok, Map.put(context, :js, File.read!(@app_js_path))}
      end

      when_ "we scan app.js for analytics dispatch and gtag calls", context do
        {:ok, context}
      end

      then_ "app.js POSTs to /api/browser/analytics/event", context do
        assert context.js =~ "/api/browser/analytics/event",
               "expected app.js to POST click events to /api/browser/analytics/event"

        {:ok, context}
      end

      then_ "app.js makes no gtag(...) call", context do
        refute context.js =~ ~r/\bgtag\s*\(/,
               "expected app.js to omit gtag(...) calls — found a direct browser-side GA dispatch"

        {:ok, context}
      end
    end
  end
end
