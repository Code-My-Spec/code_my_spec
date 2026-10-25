defmodule CodeMySpecWeb.ARunWithoutLiveEventsShowsItsRecordedCountsTest do
  @moduledoc """
  A finished run that reported nothing live still shows the counts it
  recorded. A scoped spex run that passed five tests read "0 tests, 0 failures"
  on its page, which looks like a run that selected nothing (issue ef0cea11).
  """
  use CodeMySpecSpex.Case, async: true

  import CodeMySpec.AnalysisFixtures
  import Phoenix.LiveViewTest

  alias CodeMySpec.Analysis.RunsRepository

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "its recorded tests and failures", %{conn: conn, scope: scope} do
    run = analysis_run_fixture(scope, %{source: "spex", kind: :partial})

    {:ok, run} =
      RunsRepository.finish_run(run, :completed, %{stats: %{"tests" => 5, "failures" => 0}})

    {:ok, _view, html} = live(conn, "/app/projects/#{scope.active_project_id}/runs/#{run.id}")

    assert html =~ "5 tests, 0 failures"
  end
end
