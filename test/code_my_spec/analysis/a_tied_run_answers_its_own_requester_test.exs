defmodule CodeMySpec.Analysis.ATiedRunAnswersItsOwnRequesterTest do
  @moduledoc """
  2026-10-15: team 2's coder asked for an exunit run, the harness tied it onto
  one already queued, and the tied run (59471) finished clean -- but only the
  primary's askers were told. The coder waited 40 minutes on a run that had
  already completed. A tied run now answers whoever asked for it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository

  @reported [:code_my_spec, :analysis, :run_reported]

  setup do
    scope = full_scope_fixture()
    asker = Ecto.UUID.generate()

    {:ok, primary} = RunsRepository.start_run(scope, %{source: "exunit", kind: :full})

    {:ok, tied} =
      RunsRepository.start_run(scope, %{
        source: "exunit",
        kind: :full,
        requested_by: %{"agent_id" => asker}
      })

    ref = :telemetry_test.attach_event_handlers(self(), [@reported])
    on_exit(fn -> :telemetry.detach(ref) end)
    %{scope: scope, primary: primary, tied: tied, asker: asker}
  end

  defp clean(run_id, tied_to \\ nil) do
    %{
      "run_id" => run_id,
      "source" => "exunit",
      "status" => "ok",
      "args" => [],
      "tied_to" => tied_to,
      "result" => %{
        "exit_status" => 0,
        "execution_status" => "success",
        "output" => "1 test, 0 failures",
        "stats" => %{"tests" => 1, "failures" => 0},
        "diagnostics" => []
      }
    }
  end

  test "the agent that asked for a tied run is told the run finished", ctx do
    Analysis.record_remote_result(ctx.scope, clean(ctx.primary.id))
    Analysis.record_remote_result(ctx.scope, clean(ctx.tied.id, ctx.primary.id))

    asker = ctx.asker

    assert_receive {@reported, _ref, _measurements, %{requester: ^asker, source: "exunit"}},
                   1_000,
                   "the tied run finished and nobody told the agent that asked for it"
  end

  test "a tied run nobody asked for stays quiet", ctx do
    {:ok, unasked} = RunsRepository.start_run(ctx.scope, %{source: "exunit", kind: :full})

    Analysis.record_remote_result(ctx.scope, clean(ctx.primary.id))
    Analysis.record_remote_result(ctx.scope, clean(unasked.id, ctx.primary.id))

    # Telemetry is global: other tests' runs report on this handler too, so
    # only this project's reports count (a stray one ejected 0da051c827).
    project_id = ctx.scope.active_project_id

    refute_receive {@reported, _ref, _measurements,
                    %{scope: %{active_project_id: ^project_id}, requester: nil, waiters: []}},
                   200
  end
end
