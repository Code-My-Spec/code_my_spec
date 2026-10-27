defmodule CodeMySpecSpex.Story1166.Criterion2501Spex do
  @moduledoc """
  Story 1166, criterion 2501: an ejected promotion distinguishes stages
  that never ran from stages that completed with zero duration.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Unreached stages of an ejected promotion show as not run", criterion: 2501 do
    scenario "exunit ran but spex, asset build and landing did not" do
      given_ "a promotion was ejected when exunit failed, before spex ran", context do
        entry = Fixtures.ejected_promotion_with_timing(context.scope, failed_stage: :exunit, exunit: 180)
        {:ok, Map.put(context, :promotion, entry)}
      end

      when_ "John looks at its timing", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing/#{context.promotion.id}")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "exunit shows its run time", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-stage-exunit'][data-duration-seconds='180']"
               )

        {:ok, context}
      end

      then_ "spex, the asset build and landing show as not run", context do
        for stage <- ~w(spex asset-build landing) do
          assert has_element?(
                   context.timing_view,
                   "[data-test='promotion-stage-#{stage}'][data-status='not-run']"
                 ), "#{stage} should show as not run"
        end

        {:ok, context}
      end
    end
  end
end
