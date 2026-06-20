defmodule CodeMySpecSpex.Story812.Criterion6515Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6515 — Rule 5: Custom dimensions `harness` + `location`
  are queryable for install events.

  The actual GA-admin registration of these custom dimensions is
  operator state (Admin → Custom Definitions → Custom Dimensions in
  the GA console), validated by the daily analytics snapshot.

  What the surface guarantees: the rendered install-card buttons
  (`data-event-name="install_command_copy"`) declare both the `harness`
  and `location` dimensions via `data-event-harness` and
  `data-event-location`, so once the GA admin registration lands the
  slice queries find populated dimensions.

  Driven through the marketing surface — renders the homepage and the
  product page and asserts the dimension attributes the browser receives.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "install_command_copy buttons carry harness + location dimensions" do
    scenario "rendered install-card buttons declare the harness and location dimensions" do
      given_ "the rendered marketing pages that host install cards", context do
        home = html_response(get(context.conn, "/"), 200)
        product = html_response(get(context.conn, "/products/code-my-spec"), 200)
        {:ok, Map.put(context, :html, home <> product)}
      end

      then_ "install-card buttons fire install_command_copy with the harness dimension", context do
        assert context.html =~ ~s(data-event-name="install_command_copy")
        assert context.html =~ ~s(data-event-harness="codemyspec")
        {:ok, context}
      end

      then_ "the location dimension is set for every install-card placement", context do
        assert context.html =~ ~s(data-event-location="homepage_hero")
        assert context.html =~ ~s(data-event-location="homepage_final_cta")
        assert context.html =~ ~s(data-event-location="product_page_top")
        assert context.html =~ ~s(data-event-location="product_page_final")
        {:ok, context}
      end
    end
  end
end
