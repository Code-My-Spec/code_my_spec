defmodule CodeMySpecSpex.Story1166.Criterion2500Spex do
  @moduledoc """
  Story 1166 — I can see where a promotion's time goes.
  Criterion 2500 — A landed promotion's stage durations account for the
  whole time from request to landing.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John sees where a landed promotion's time went", criterion: 2500 do
    scenario "a landed promotion shows every stage and accounts for its elapsed time" do
      given_ "a promotion waited 11 minutes, built the gate for 2 minutes, ran compiler for 1 minute, credo for 30 seconds, exunit for 5 minutes and spex for 5 minutes, then landed", context do
        entry =
          Fixtures.landed_promotion_with_timing(context.scope,
            queue_wait: 660,
            gate_build: 120,
            compiler: 60,
            credo: 30,
            exunit: 300,
            spex: 300,
            asset_build: 0,
            landing: 0
          )

        {:ok, Map.put(context, :promotion, entry)}
      end

      when_ "John opens that promotion's timing", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/promotion-timing/#{context.promotion.id}"
          )

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "he sees each stage with its duration", context do
        for {stage, seconds} <- [
              {"queue-wait", 660},
              {"gate-build", 120},
              {"compiler", 60},
              {"credo", 30},
              {"exunit", 300},
              {"spex", 300},
              {"asset-build", 0},
              {"landing", 0}
            ] do
          assert has_element?(
                   context.timing_view,
                   "[data-test='promotion-stage-#{stage}'][data-duration-seconds='#{seconds}']"
                 ), "missing #{stage} duration"
        end

        {:ok, context}
      end

      then_ "the stages account for the whole time from promotion to landing", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-total'][data-duration-seconds='1470']"
               )

        {:ok, context}
      end
    end
  end
end
