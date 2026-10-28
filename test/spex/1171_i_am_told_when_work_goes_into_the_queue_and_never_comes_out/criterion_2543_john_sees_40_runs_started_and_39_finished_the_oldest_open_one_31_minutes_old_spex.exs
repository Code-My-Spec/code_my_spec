defmodule CodeMySpecSpex.Story1171.Criterion2543Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2543 — John sees 40 runs started and 39 finished, the oldest open one 31 minutes old.
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

  spex "Promotion timing shows started, finished and oldest unfinished analysis run",
    criterion: 2543 do
    scenario "40 runs started in the last 24 hours, 39 finished, and the remaining run is 31 minutes old" do
      given_ "the analysis ledger has 40 recent starts, 39 finishes and one 31-minute-old open run",
             context do
        :ok =
          Fixtures.record_analysis_run_history(context.scope,
            started: 40,
            finished: 39,
            oldest_open_minutes: 31,
            within_hours: 24
          )

        {:ok, context}
      end

      when_ "John opens promotion timing", context do
        page = Fixtures.open_promotion_timing(context.scope)
        {:ok, Map.put(context, :page, page)}
      end

      then_ "he sees 40 started, 39 finished and the oldest open run aged 31 minutes", context do
        assert context.page.started == 40
        assert context.page.finished == 39
        assert context.page.oldest_open_minutes == 31
        {:ok, context}
      end
    end
  end
end
