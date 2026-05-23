defmodule CodeMySpecSpex.Story812.Criterion6518Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6518 — Rule 6: window.GA_MEASUREMENT_ID is never set
  in the browser.

  HTML + JS-grep assertion (no cassette): when all GA delivery is
  server-side via MP, the browser never needs to know the measurement
  ID. Verifies (a) no rendered HTML assigns window.GA_MEASUREMENT_ID,
  and (b) `assets/js/app.js` carries no reference to it.

  Driving spec — will FAIL until assets/js/app.js drops the
  `window.GA_MEASUREMENT_ID` reference (currently at line ~57) and
  root.html.heex drops the gtag block.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @app_js_path "assets/js/app.js"

  spex "window.GA_MEASUREMENT_ID is never set in the browser" do
    scenario "no script sets window.GA_MEASUREMENT_ID and app.js has no GA references" do
      given_ "the app's shipped browser bundle", context do
        {:ok, context}
      end

      when_ "we render any browser page and inspect app.js", context do
        conn = Phoenix.ConnTest.get(context.conn, "/")
        body = conn.resp_body || ""
        js = File.read!(@app_js_path)
        {:ok, context |> Map.put(:body, body) |> Map.put(:js, js)}
      end

      then_ "no rendered script assigns window.GA_MEASUREMENT_ID", context do
        refute context.body =~ ~r/window\.GA_MEASUREMENT_ID/,
               "expected rendered HTML to omit window.GA_MEASUREMENT_ID"

        {:ok, context}
      end

      then_ "assets/js/app.js contains no GA_MEASUREMENT_ID or gtag references",
            context do
        refute context.js =~ ~r/GA_MEASUREMENT_ID/,
               "expected app.js to omit GA_MEASUREMENT_ID"

        refute context.js =~ ~r/\bgtag\s*\(/,
               "expected app.js to omit gtag(...) calls"

        {:ok, context}
      end
    end
  end
end
