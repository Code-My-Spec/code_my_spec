defmodule CodeMySpec.Analysis.TestTimingsSurviveRunCompletionTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Repo

  test "completed gate runs retain streamed test and file durations" do
    scope = full_scope_fixture()
    {:ok, run} = RunsRepository.start_run(scope, %{source: "exunit", kind: :full})
    file = "test/cms_harness/sync_path_test.exs"

    assert :ok =
             Analysis.record_live_event(scope, run.id, %{
               "event" => "file_started",
               "file" => file
             })

    assert :ok =
             Analysis.record_live_event(scope, run.id, %{
               "event" => "test",
               "name" => "sync path",
               "file" => file,
               "state" => "passed",
               "duration" => 39_000
             })

    assert :ok =
             Analysis.record_live_event(scope, run.id, %{
               "event" => "file_finished",
               "file" => file
             })

    assert {:ok, _} =
             Analysis.record_remote_result(scope, %{
               "run_id" => run.id,
               "source" => "exunit",
               "status" => "ok",
               "result" => %{
                 "exit_status" => 0,
                 "execution_status" => "success",
                 "output" => "1 test, 0 failures",
                 "stats" => %{},
                 "diagnostics" => []
               }
             })

    completed = Repo.reload!(run)

    assert completed.stats["timings"]["tests"] == [
             %{"name" => "sync path", "file" => file, "duration_us" => 39_000_000}
           ]

    assert [%{"file" => ^file, "duration_us" => duration}] = completed.stats["timings"]["files"]
    assert is_integer(duration) and duration >= 0
  end
end
