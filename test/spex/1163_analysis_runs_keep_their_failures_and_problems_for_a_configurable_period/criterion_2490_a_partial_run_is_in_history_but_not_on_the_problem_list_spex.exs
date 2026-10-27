defmodule CodeMySpecSpex.Story1163.Criterion2490Spex do
  @moduledoc """
  Story 1163: Analysis runs keep their failures and problems for a configurable period.
  Criterion 2490: A partial run is in history but not on the problem list.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A partial exunit failure enters history without changing current problems",
    criterion: 2490 do
    scenario "a failed partial run does not reconcile the working copy problem list" do
      given_ "the working copy has a current problem list before a partial exunit run", context do
        {:ok, problems_before} =
          ToolLibrary.run("list_problems", %{"source" => "exunit"}, %{scope: context.scope})

        {:ok, Map.put(context, :problems_before, problems_before)}
      end

      when_ "a partial exunit run fails one test and finishes", context do
        failure = %{file: "test/partial_test.exs", name: "test partial failure"}

        run =
          Fixtures.finished_analysis_run_with_findings(context.scope,
            source: "exunit",
            full: false,
            failures: [failure]
          )

        {:ok, history_body} =
          ToolLibrary.run("get_analysis_history", %{"source" => "exunit"}, %{scope: context.scope})

        {:ok, problems_after} =
          ToolLibrary.run("list_problems", %{"source" => "exunit"}, %{scope: context.scope})

        recorded_run = Enum.find(Jason.decode!(history_body)["runs"], &(&1["run_id"] == run.id))

        {:ok,
         Map.merge(context, %{
           recorded_run: recorded_run,
           expected_failure: failure,
           problems_after: problems_after
         })}
      end

      then_ "the failed test remains in the partial run's history", context do
        assert context.recorded_run
        assert context.recorded_run["partial"] == true

        assert Enum.any?(context.recorded_run["failures"], fn failure ->
                 failure["file"] == context.expected_failure.file and
                   failure["name"] == context.expected_failure.name
               end)

        {:ok, context}
      end

      then_ "the working copy's current problem list is unchanged", context do
        assert context.problems_after == context.problems_before
        {:ok, context}
      end
    end
  end
end
