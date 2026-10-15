defmodule CodeMySpec.Analysis.ATargetedRunAnswersItsOwnRequesterTest do
  @moduledoc """
  2026-10-15: team 4's QA started targeted exunit and spex runs (59901, 59902)
  and ended its turn to wait for the answer. Both finished clean in seconds, but
  a partial run skipped the report, so nobody told it. A targeted run now
  answers whoever asked for it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository

  @reported [:code_my_spec, :analysis, :run_reported]

  setup do
    scope = full_scope_fixture()
    ref = :telemetry_test.attach_event_handlers(self(), [@reported])
    on_exit(fn -> :telemetry.detach(ref) end)
    %{scope: scope}
  end

  defp clean(run_id) do
    %{
      "run_id" => run_id,
      "source" => "exunit",
      "status" => "ok",
      "args" => ["test/some_test.exs"],
      "result" => %{
        "exit_status" => 0,
        "execution_status" => "success",
        "output" => "1 test, 0 failures",
        "stats" => %{"tests" => 1, "failures" => 0},
        "diagnostics" => []
      }
    }
  end

  test "the agent that asked for a targeted run is told it finished", %{scope: scope} do
    asker = Ecto.UUID.generate()

    {:ok, run} =
      RunsRepository.start_run(scope, %{
        source: "exunit",
        kind: :partial,
        requested_by: %{"agent_id" => asker}
      })

    Analysis.record_remote_result(scope, clean(run.id))

    assert_receive {@reported, _ref, _measurements, %{requester: ^asker, source: "exunit"}},
                   1_000,
                   "the targeted run finished and nobody told the agent that asked for it"
  end

  test "a targeted run nobody asked for stays quiet", %{scope: scope} do
    {:ok, run} = RunsRepository.start_run(scope, %{source: "exunit", kind: :partial})

    Analysis.record_remote_result(scope, clean(run.id))

    project_id = scope.active_project_id

    refute_receive {@reported, _ref, _measurements, %{scope: %{active_project_id: ^project_id}}},
                   200
  end
end
