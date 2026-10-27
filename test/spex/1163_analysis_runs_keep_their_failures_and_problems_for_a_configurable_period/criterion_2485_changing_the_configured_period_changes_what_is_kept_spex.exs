defmodule CodeMySpecSpex.Story1163.Criterion2485Spex do
  @moduledoc """
  Story 1163 — Analysis runs keep their failures and problems for a configurable period.
  Criterion 2485 — Changing the configured period changes what is kept.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Changing retention changes which completed runs survive pruning", criterion: 2485 do
    scenario "a ten-day run expires when retention changes from thirty to seven days" do
      given_ "history initially retains thirty days and has a ten-day run with findings",
             context do
        :ok = Fixtures.configure_analysis_retention_days(30)
        run = Fixtures.finished_analysis_run_with_findings(context.scope, days_ago: 10)
        {:ok, Map.put(context, :run_id, run.id)}
      end

      when_ "retention is changed to seven days and the scheduled prune runs", context do
        :ok = Fixtures.configure_analysis_retention_days(7)
        :ok = Fixtures.run_scheduled_analysis_history_prune(context.scope)
        {:ok, context}
      end

      then_ "the ten-day run and its findings have expired", context do
        {:ok, body} = ToolLibrary.run("get_analysis_history", %{}, %{scope: context.scope})
        history = Jason.decode!(body)
        refute Enum.any?(history["runs"], &(&1["run_id"] == context.run_id))
        {:ok, context}
      end
    end
  end
end
