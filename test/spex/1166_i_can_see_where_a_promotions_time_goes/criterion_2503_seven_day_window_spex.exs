defmodule CodeMySpecSpex.Story1166.Criterion2503Spex do
  @moduledoc "Story 1166, criterion 2503: the seven-day timing window."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John widens the promotion timing window to seven days", criterion: 2503 do
    scenario "every stage statistic includes promotions from the whole week" do
      given_ "promotions ran six days, three days and twelve hours ago", context do
        for {age_hours, seconds} <- [{144, 60}, {72, 60}, {12, 120}] do
          Fixtures.landed_promotion_with_timing(context.scope,
            landed_at: DateTime.add(DateTime.utc_now(), -age_hours * 3600, :second),
            queue_wait: seconds,
            gate_build: seconds,
            compiler: seconds,
            credo: seconds,
            exunit: seconds,
            spex: seconds,
            asset_build: seconds,
            landing: seconds
          )
        end

        {:ok, context}
      end

      when_ "John chooses the last seven days", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")
        view |> element("[data-test='promotion-window-7d']") |> render_click()
        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "every median, p90 and total covers those seven days", context do
        assert has_element?(context.timing_view, "[data-test='promotion-window'][data-window='7d']")
        assert has_element?(context.timing_view, "[data-test='promotion-outcome-landed'][data-count='3']")

        for stage <- ~w(queue-wait gate-build compiler credo exunit spex asset-build landing) do
          summary = "[data-test='promotion-summary-landed-#{stage}']"
          assert has_element?(context.timing_view, "#{summary} [data-stat='median'][data-duration-seconds='60']")
          assert has_element?(context.timing_view, "#{summary} [data-stat='p90'][data-duration-seconds='120']")
          assert has_element?(context.timing_view, "#{summary} [data-stat='total'][data-duration-seconds='240']")
        end

        {:ok, context}
      end
    end
  end
end
