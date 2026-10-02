defmodule CodeMySpec.Analysis.AFailedSuiteKeepsWhatItSaidTest do
  @moduledoc """
  A remote exunit run that did not finish keeps its output and exit status on
  the failed run. Run 54391 kept one line — a logged disconnect picked out of
  181 seconds of output — and nothing else, so the cause of the crash it
  recorded could not be read afterwards.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Repo

  test "the failed run carries the suite's output and exit status" do
    scope = full_scope_fixture()
    {:ok, run} = RunsRepository.start_run(scope, %{source: "exunit", kind: :full})

    output = "........\n** (RuntimeError) after_suite blew up"

    Analysis.record_remote_result(scope, %{
      "run_id" => run.id,
      "source" => "exunit",
      "status" => "ok",
      "result" => %{
        "exit_status" => 1,
        "execution_status" => "error",
        "output" => output,
        "stats" => %{},
        "diagnostics" => []
      }
    })

    failed = Repo.reload!(run)

    assert failed.status == :failed
    assert failed.output == output
    assert failed.exit_status == 1
    assert failed.stats["error"] =~ "after_suite blew up"
  end
end
