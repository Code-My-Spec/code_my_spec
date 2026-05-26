defmodule CodeMySpecSpex.Story812.Criterion6534Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6534 — Rule 4 (hybrid): Root layout loads gtag.js async
  with the GA4 measurement id.

  Hybrid design: browser pageviews and behavior events are handled by
  gtag.js. The root layout must load the gtag async snippet with the
  measurement id exposed to the browser — so GA4 can track page_view,
  sessions, engagement, bot exclusion, and referrer attribution natively.

  Two assertions:
  1. The root layout HTML includes the async `gtag.js` script tag
     pointing at `https://www.googletagmanager.com/gtag/js?id=G-...`.
  2. The rendered HTML sets `window.GA_MEASUREMENT_ID` (or equivalent
     inline gtag config) so app.js can reference the measurement id
     without hardcoding it in JS.

  Uses a live-render of the homepage to observe the actual `<head>`
  output. Fails if the gtag snippet is absent or if the measurement id
  is not surfaced to the browser.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "Root layout loads gtag.js async with GA4 measurement id" do
    scenario "homepage renders with gtag async script in <head>" do
      given_ "an unauthenticated request to the homepage", context do
        {:ok, context}
      end

      when_ "the page is rendered", context do
        conn = get(context.conn, "/")
        {:ok, Map.put(context, :html, html_response(conn, 200))}
      end

      then_ "a gtag.js script tag is present in the page", context do
        assert context.html =~ "googletagmanager.com/gtag/js",
               "expected an async gtag.js script tag from googletagmanager.com in the rendered HTML"

        {:ok, context}
      end

      then_ "the gtag snippet is loaded asynchronously", context do
        # The gtag script tag must carry `async` in some form.
        # The URL path is `gtag/js` (not `gtag.js`) — check for `async`
        # on any `<script>` element that references googletagmanager.
        # Accept bare `async`, `async=""`, or `async="async"`.
        assert context.html =~
                 ~r/<script[^>]*async[^>]*googletagmanager|<script[^>]*googletagmanager[^>]*async/,
               "expected the gtag.js script tag from googletagmanager.com to carry the `async` attribute"

        {:ok, context}
      end

      then_ "the GA4 measurement id is present in the page for gtag config", context do
        # The measurement id must appear in the rendered HTML so the
        # gtag snippet can configure the right property. Accept either
        # a `gtag('config', 'G-...')` call or a `window.GA_MEASUREMENT_ID`
        # assignment — the implementation may choose either form.
        assert context.html =~ ~r/G-[A-Z0-9]+/,
               "expected a GA4 measurement id (G-...) in the rendered HTML for gtag config"

        {:ok, context}
      end
    end
  end
end
