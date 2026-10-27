defmodule CodeMySpecSpex.Story1163.Criterion2488Spex do
  @moduledoc """
  Story 1163: Analysis runs keep their failures and problems for a configurable period.
  Criterion 2488: A partial spex run keeps its failures and is marked partial.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A one-file spex run retains its failed criterion and partial status", criterion: 2488 do
    scenario "one failed scenario remains attached to its partial run" do
      given_ "a spex run limited to one file fails a scenario", context do
        file = "test/spex/example/criterion_2488_spex.exs"

        run =
          Fixtures.finished_analysis_run_with_findings(context.scope,
            source: "spex",
            partial: true,
            paths: [file],
            failures: [%{file: file, name: "scenario fails", criterion: 2488}]
          )

        {:ok, Map.merge(context, %{run: run, spex_file: file})}
      end

      when_ "the run finishes and its history is requested", context do
        {:ok, body} =
          ToolLibrary.run("get_analysis_history", %{"source" => "spex"}, %{scope: context.scope})

        run = Enum.find(Jason.decode!(body)["runs"], &(&1["run_id"] == context.run.id))
        {:ok, Map.put(context, :recorded_run, run)}
      end

      then_ "the run retains the failed scenario with its criterion", context do
        assert context.recorded_run

        assert [%{"file" => file, "name" => "scenario fails", "criterion" => 2488}] =
                 context.recorded_run["failures"]

        assert file == context.spex_file
        {:ok, context}
      end

      then_ "the spex run is marked partial", context do
        assert context.recorded_run["source"] == "spex"
        assert context.recorded_run["partial"] == true
        {:ok, context}
      end
    end
  end
end
