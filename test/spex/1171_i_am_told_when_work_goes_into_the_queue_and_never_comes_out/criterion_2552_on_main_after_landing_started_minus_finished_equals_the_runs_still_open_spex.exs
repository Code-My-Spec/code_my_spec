defmodule CodeMySpecSpex.Story1171.Criterion2552Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2552 — On main after landing, started minus finished equals the runs still open.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Promotion timing reconciles with unfinished analysis history", criterion: 2552 do
    scenario "40 starts and 39 finishes leave exactly one open run in the last 24 hours" do
      given_ "story 1171 has landed on main with 40 recent starts, 39 finishes and one open run",
             context do
        :ok = Fixtures.land_story_on_main(context.scope, 1171)

        :ok =
          Fixtures.record_analysis_run_history(context.scope,
            started: 40,
            finished: 39,
            oldest_open_minutes: 31,
            within_hours: 24
          )

        {:ok, context}
      end

      when_ "John compares promotion timing with analysis history for the same 24-hour window",
            context do
        timing = Fixtures.open_promotion_timing(context.scope)
        history = Fixtures.analysis_history(context.scope, within_hours: 24)
        {:ok, Map.merge(context, %{timing: timing, history: history})}
      end

      then_ "started minus finished equals the number of unfinished history entries", context do
        unfinished = Enum.count(context.history, &is_nil(&1.finished_at))
        assert context.timing.started == 40
        assert context.timing.finished == 39
        assert unfinished == 1
        assert context.timing.started - context.timing.finished == unfinished
        {:ok, context}
      end
    end
  end
end
