defmodule CodeMySpecSpex.Story1171.Criterion2540Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2540 — A long run that keeps sending events within its limit is not stuck.
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

  spex "A long run with recent events remains within its limit", criterion: 2540 do
    scenario "a twenty-minute spex run is below twice its p90 and reported recently" do
      given_ "a spex run has been unfinished for twenty minutes with a fourteen-minute p90",
             context do
        :ok = Fixtures.record_analysis_duration_history(context.scope, "spex", p90_minutes: 14)
        :ok = Fixtures.configure_stuck_work(context.scope, duration_multiplier: 2)
        run = Fixtures.start_analysis_run(context.scope, "spex", started_minutes_ago: 20)
        {:ok, Map.put(context, :run_id, run.id)}
      end

      given_ "its last event came thirty seconds ago", context do
        :ok = Fixtures.set_last_analysis_event(context.scope, context.run_id, seconds_ago: 30)
        {:ok, context}
      end

      when_ "stuck runs are checked", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}
        {:ok, body} = ToolLibrary.run("get_stuck_work", %{}, tool_context)
        {:ok, Map.put(context, :stuck_work, Jason.decode!(body))}
      end

      then_ "the run is not reported stuck", context do
        refute Enum.any?(context.stuck_work["runs"], fn run ->
                 run["run_id"] == context.run_id and run["status"] == "stuck"
               end)

        {:ok, context}
      end
    end
  end
end
