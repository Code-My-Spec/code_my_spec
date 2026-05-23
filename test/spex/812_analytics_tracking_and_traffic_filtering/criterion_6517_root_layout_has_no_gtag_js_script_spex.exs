defmodule CodeMySpecSpex.Story812.Criterion6517Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6517 — Rule 6: Root layout has no gtag.js script.

  HTML-assertion pattern (no cassette needed): renders a page through
  the root layout and asserts the response HTML contains no
  `<script src="...googletagmanager.com/gtag/js...">` tag and no
  inline `gtag(...)` calls. When all GA delivery is server-side via
  MP, no browser-side gtag is loaded.

  This spex will FAIL until `lib/code_my_spec_web/components/layouts/root.html.heex`
  drops the gtag block (currently at line ~83). It's a driving spec.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "Root layout has no gtag.js script" do
    scenario "the response HTML for any browser-pipeline page contains no gtag references" do
      given_ "a request to a public marketing page", context do
        {:ok, context}
      end

      when_ "the response renders through root.html.heex", context do
        conn = Phoenix.ConnTest.get(context.conn, "/")
        {:ok, Map.put(context, :body, conn.resp_body || "")}
      end

      then_ "no <script src=\"...googletagmanager.com/gtag/js...\"> tag is present",
            context do
        refute context.body =~ ~r/googletagmanager\.com\/gtag\/js/,
               "expected root layout to omit the gtag.js <script> tag"

        {:ok, context}
      end

      then_ "no inline gtag(...) calls are present", context do
        refute context.body =~ ~r/\bgtag\s*\(/,
               "expected root layout to omit inline gtag(...) calls"

        {:ok, context}
      end
    end
  end
end
