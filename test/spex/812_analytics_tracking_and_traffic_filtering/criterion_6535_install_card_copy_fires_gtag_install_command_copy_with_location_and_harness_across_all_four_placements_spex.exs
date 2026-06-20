defmodule CodeMySpecSpex.Story812.Criterion6535Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6535 — Rule 4 (hybrid): Install-card copy fires
  `gtag('event', 'install_command_copy', ...)` with `location` and
  `harness` across all four placements.

  Hybrid design: install_command_copy is a browser behavior event fired
  by gtag from the copy-button handler. The button hands gtag its
  parameters through `data-event-name` / `data-event-location` /
  `data-event-harness` attributes — so the surface contract this spec
  guards is that all four install-card placements render those
  attributes. (The gtag call itself is browser JS, exercised by browser
  QA, not a spec.)

  The four placements are:
    - homepage_hero        ("/")
    - homepage_final_cta   ("/")
    - product_page_top     ("/products/code-my-spec")
    - product_page_final   ("/products/code-my-spec")

  Driven through the marketing surface. Fails if a placement is dropped
  or stops carrying its install_command_copy / harness / location markup.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "Install-card copy fires gtag install_command_copy with location + harness across all four placements" do
    scenario "all four install-card placements render install_command_copy with harness + location" do
      given_ "the rendered marketing pages that host the install cards", context do
        home = html_response(get(context.conn, "/"), 200)
        product = html_response(get(context.conn, "/products/code-my-spec"), 200)
        {:ok, Map.put(context, :html, home <> product)}
      end

      then_ "install cards fire install_command_copy carrying the harness param", context do
        assert context.html =~ ~s(data-event-name="install_command_copy")
        assert context.html =~ ~s(data-event-harness="codemyspec")
        {:ok, context}
      end

      then_ "the homepage placements are present", context do
        assert context.html =~ ~s(data-event-location="homepage_hero")
        assert context.html =~ ~s(data-event-location="homepage_final_cta")
        {:ok, context}
      end

      then_ "the product-page placements are present", context do
        assert context.html =~ ~s(data-event-location="product_page_top")
        assert context.html =~ ~s(data-event-location="product_page_final")
        {:ok, context}
      end
    end
  end
end
