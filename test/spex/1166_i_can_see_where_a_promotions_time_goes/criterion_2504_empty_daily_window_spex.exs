defmodule CodeMySpecSpex.Story1166.Criterion2504Spex do
  @moduledoc "Story 1166, criterion 2504: an empty timing window."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An empty day says no promotions ran", criterion: 2504 do
    scenario "a promotion outside the window does not produce zero medians" do
      given_ "no promotion ran in the last 24 hours", context do
        Fixtures.landed_promotion_with_timing(context.scope,
          landed_at: DateTime.add(DateTime.utc_now(), -48 * 3600, :second),
          queue_wait: 60,
          gate_build: 60,
          compiler: 60,
          credo: 60,
          exunit: 60,
          spex: 60,
          asset_build: 60,
          landing: 60
        )

        {:ok, context}
      end

      when_ "John looks at promotion timing for the last 24 hours", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "the page says no promotions ran in that window", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-window'][data-window='24h']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-timing-empty']",
                 "No promotions ran"
               )

        {:ok, context}
      end

      then_ "the page shows no medians instead of zero medians", context do
        refute has_element?(context.timing_view, "[data-stat='median']")
        {:ok, context}
      end
    end
  end
end
