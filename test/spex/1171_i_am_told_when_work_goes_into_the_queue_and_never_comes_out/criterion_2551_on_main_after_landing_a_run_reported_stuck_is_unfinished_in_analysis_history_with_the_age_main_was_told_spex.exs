defmodule CodeMySpecSpex.Story1171.Criterion2551Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2551 — On main after landing, a run reported stuck is unfinished in analysis history with the age Main was told.
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

  spex "A stuck run reported to Main remains unfinished in analysis history at the reported age",
    criterion: 2551 do
    scenario "run 64421 is reported stuck at 31 minutes after the story lands on main" do
      given_ "story 1171 has landed on main and run 64421 began 31 minutes ago without finishing",
             context do
        :ok = Fixtures.land_story_on_main(context.scope, 1171)

        run =
          Fixtures.start_analysis_run(context.scope, "spex",
            run_number: 64_421,
            started_minutes_ago: 31
          )

        :ok = Fixtures.set_last_analysis_event(context.scope, run.id, minutes_ago: 12)
        {:ok, Map.put(context, :run_id, run.id)}
      end

      when_ "Main is told that run 64421 is stuck and John opens its analysis history", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}
        {:ok, _body} = ToolLibrary.run("get_stuck_work", %{}, tool_context)

        notification =
          Enum.find(
            Fixtures.main_stuck_notifications(context.scope),
            &String.contains?(&1, "64421")
          )

        history = Fixtures.analysis_history_entry(context.scope, context.run_id)
        {:ok, Map.merge(context, %{notification: notification, history: history})}
      end

      then_ "the history entry is unfinished and its start time matches the 31-minute age Main was told",
            context do
        assert context.notification =~ "31 minutes"
        assert context.history.finished_at == nil
        assert context.history.id == context.run_id

        assert_in_delta DateTime.diff(DateTime.utc_now(), context.history.started_at, :second),
                        31 * 60,
                        60

        {:ok, context}
      end
    end
  end
end
