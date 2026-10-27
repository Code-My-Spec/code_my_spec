defmodule CodeMySpecSpex.Story1163.Criterion2486Spex do
  @moduledoc """
  Story 1163 — Analysis runs keep their failures and problems for a configurable period.
  Criterion 2486 — More than twenty runs of one source are kept inside the window.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every in-window run survives regardless of the old twenty-run cap", criterion: 2486 do
    scenario "twenty-five exunit runs retain their findings" do
      given_ "thirty-day retention and twenty-five completed exunit runs from yesterday",
             context do
        :ok = Fixtures.configure_analysis_retention_days(30)

        run_ids =
          for _ <- 1..25 do
            run =
              Fixtures.finished_analysis_run_with_findings(context.scope,
                source: "exunit",
                days_ago: 1
              )

            run.id
          end

        {:ok, Map.put(context, :run_ids, run_ids)}
      end

      when_ "the scheduled history prune runs", context do
        :ok = Fixtures.run_scheduled_analysis_history_prune(context.scope)
        {:ok, context}
      end

      then_ "all twenty-five runs and their failures remain in history", context do
        {:ok, body} =
          ToolLibrary.run("get_analysis_history", %{"source" => "exunit"}, %{scope: context.scope})

        runs = Jason.decode!(body)["runs"]
        matching = Enum.filter(runs, &(&1["run_id"] in context.run_ids))
        assert length(matching) == 25
        assert Enum.all?(matching, &(length(&1["failures"]) == 1))
        {:ok, context}
      end
    end
  end
end
