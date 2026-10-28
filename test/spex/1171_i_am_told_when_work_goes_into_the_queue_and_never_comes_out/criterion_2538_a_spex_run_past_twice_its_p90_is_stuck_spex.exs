defmodule CodeMySpecSpex.Story1171.Criterion2538Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2538 — A spex run past twice its p90 is stuck.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A spex run past twice its p90 is stuck", criterion: 2538 do
    scenario "a 29-minute open run exceeds twice its 14-minute p90" do
      given_ "spex runs in the last day have a 14-minute p90", context do
        :ok = Fixtures.record_analysis_duration_history(context.scope, "spex", p90_minutes: 14)
        {:ok, context}
      end

      given_ "the configured duration multiplier is two", context do
        :ok = Fixtures.configure_stuck_work(context.scope, duration_multiplier: 2)
        {:ok, context}
      end

      when_ "a spex run has remained unfinished for 29 minutes", context do
        run = Fixtures.start_analysis_run(context.scope, "spex", started_minutes_ago: 29)
        tool_context = %{scope: context.scope, current_scope: context.scope}
        {:ok, body} = ToolLibrary.run("get_stuck_work", %{}, tool_context)
        {:ok, Map.merge(context, %{run_id: run.id, stuck_work: Jason.decode!(body)})}
      end

      then_ "the run is reported stuck", context do
        assert Enum.any?(context.stuck_work["runs"], fn run ->
                 run["run_id"] == context.run_id and run["status"] == "stuck"
               end)

        {:ok, context}
      end
    end
  end
end
