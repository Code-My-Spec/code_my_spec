defmodule CodeMySpecSpex.Story1171.Criterion2539Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2539 — A run that has gone silent is stuck before its time is up.
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

  spex "A run silent for the configured limit is stuck before its p90", criterion: 2539 do
    scenario "a six-minute exunit run has sent no event for five minutes" do
      given_ "an exunit run started six minutes ago, within its p90", context do
        :ok = Fixtures.record_analysis_duration_history(context.scope, "exunit", p90_minutes: 14)
        run = Fixtures.start_analysis_run(context.scope, "exunit", started_minutes_ago: 6)
        {:ok, Map.put(context, :run_id, run.id)}
      end

      given_ "the silence limit is five minutes", context do
        :ok = Fixtures.configure_stuck_work(context.scope, silence_minutes: 5)
        {:ok, context}
      end

      when_ "no event has come from the run for five minutes", context do
        :ok = Fixtures.set_last_analysis_event(context.scope, context.run_id, minutes_ago: 5)
        tool_context = %{scope: context.scope, current_scope: context.scope}
        {:ok, body} = ToolLibrary.run("get_stuck_work", %{}, tool_context)
        {:ok, Map.put(context, :stuck_work, Jason.decode!(body))}
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
