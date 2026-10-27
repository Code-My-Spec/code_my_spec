defmodule CodeMySpecSpex.Story1163.Criterion2487Spex do
  @moduledoc """
  Story 1163: Analysis runs keep their failures and problems for a configurable period.
  Criterion 2487: A full exunit run keeps its failures.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A full exunit run retains both failures and its provenance", criterion: 2487 do
    scenario "two failed tests remain attached to the completed run" do
      given_ "a working copy at commit X has a full exunit run with two failed tests", context do
        failures = [
          %{file: "test/code_my_spec/alpha_test.exs", name: "test alpha fails"},
          %{file: "test/code_my_spec/beta_test.exs", name: "test beta fails"}
        ]

        run =
          Fixtures.finished_analysis_run_with_findings(context.scope,
            source: "exunit",
            full: true,
            commit: "commit-X",
            failures: failures
          )

        {:ok, Map.merge(context, %{run: run, expected_failures: failures})}
      end

      when_ "the run finishes and its history is requested", context do
        {:ok, body} =
          ToolLibrary.run("get_analysis_history", %{"source" => "exunit"}, %{scope: context.scope})

        run = Enum.find(Jason.decode!(body)["runs"], &(&1["run_id"] == context.run.id))
        {:ok, Map.put(context, :recorded_run, run)}
      end

      then_ "both failures retain their test file and name", context do
        assert context.recorded_run
        assert length(context.recorded_run["failures"]) == 2

        for failure <- context.expected_failures do
          assert Enum.any?(context.recorded_run["failures"], fn recorded ->
                   recorded["file"] == failure.file and recorded["name"] == failure.name
                 end)
        end

        {:ok, context}
      end

      then_ "the run records commit X, its working copy, exunit source and full coverage",
            context do
        assert context.recorded_run["commit"] == "commit-X"
        assert context.recorded_run["working_copy_id"] == context.run.working_copy_id
        assert context.recorded_run["source"] == "exunit"
        assert context.recorded_run["partial"] == false
        {:ok, context}
      end
    end
  end
end
