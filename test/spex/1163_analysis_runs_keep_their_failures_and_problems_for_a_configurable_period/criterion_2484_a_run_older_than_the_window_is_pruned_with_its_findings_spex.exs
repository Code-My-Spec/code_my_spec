defmodule CodeMySpecSpex.Story1163.Criterion2484Spex do
  @moduledoc """
  Story 1163 — Analysis runs keep their failures and problems for a configurable period.
  Criterion 2484 — A run older than the window is pruned with its findings.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Old analysis runs and their findings expire together", criterion: 2484 do
    scenario "a 31-day run is removed while a 29-day run remains" do
      given_ "analysis history is configured to retain 30 days", context do
        :ok = Fixtures.configure_analysis_retention_days(30)
        {:ok, context}
      end

      given_ "a run finished 31 days ago with a failure and a problem", context do
        old_run = Fixtures.finished_analysis_run_with_findings(context.scope, days_ago: 31)
        {:ok, Map.put(context, :old_run_id, old_run.id)}
      end

      given_ "a run finished 29 days ago with a failure and a problem", context do
        recent_run = Fixtures.finished_analysis_run_with_findings(context.scope, days_ago: 29)
        {:ok, Map.put(context, :recent_run_id, recent_run.id)}
      end

      when_ "the scheduled history prune runs", context do
        :ok = Fixtures.run_scheduled_analysis_history_prune(context.scope)
        {:ok, context}
      end

      then_ "the older run and both of its findings are absent from history", context do
        {:ok, body} = ToolLibrary.run("get_analysis_history", %{}, %{scope: context.scope})
        history = Jason.decode!(body)
        refute Enum.any?(history["runs"], &(&1["run_id"] == context.old_run_id))
        {:ok, Map.put(context, :history, history)}
      end

      then_ "the recent run retains its failure and problem", context do
        run = Enum.find(context.history["runs"], &(&1["run_id"] == context.recent_run_id))
        assert run
        assert length(run["failures"]) == 1
        assert length(run["problems"]) == 1
        {:ok, context}
      end
    end
  end
end
