defmodule CodeMySpec.Analysis.FailRunningScopeTest do
  @moduledoc """
  Closing runs is a write, and a scope with no harness names no runs to close.

  `fail_running/3` filtered with `where([r], r.harness_id == ^scope.active_harness_id)`.
  Ecto forbids `== nil` and raises `ArgumentError` rather than matching nothing,
  so a scope without a harness crashed the caller instead of closing nothing —
  six `%ArgumentError{}` out of `Analysis.fail_in_flight/3` during a channel
  join storm, while `scope_to_harness/2` two hundred lines above had handled
  that case all along.

  Reading nil as "no filter" is right for the queries that *report*: the UI asks
  about a project, not a checkout. It is wrong for one that *writes*. Closing
  every harness's in-flight runs because this scope names none would fail runs
  belonging to working copies that are still going, and the damage would surface
  as some unrelated agent's sweep coming back `:harness_disconnected` — a
  failure with no visible connection to its cause.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.RunsRepository

  defp running_run(scope) do
    {:ok, run} = RunsRepository.start_run(scope, %{source: "credo", kind: :full})
    run
  end

  test "a scope with no harness closes nothing rather than raising" do
    scope = full_scope_fixture()
    run = running_run(scope)

    assert {:ok, 0} = RunsRepository.fail_running(%{scope | active_harness_id: nil}, :probe, [])

    assert RunsRepository.get_run_in_project(scope, run.id).status == :running,
           "another checkout's run must survive a scope that names no harness"
  end

  test "a scope with a harness still closes its own" do
    scope = full_scope_fixture()
    run = running_run(scope)

    assert {:ok, 1} = RunsRepository.fail_running(scope, :probe, [])
    assert RunsRepository.get_run_in_project(scope, run.id).status == :failed
  end

  # The claim mechanism has to keep working through the guard: a harness that
  # says it is still holding a run keeps it.
  test "a claimed run is left running" do
    scope = full_scope_fixture()
    run = running_run(scope)

    assert {:ok, 0} = RunsRepository.fail_running(scope, :probe, [run.id])
    assert RunsRepository.get_run_in_project(scope, run.id).status == :running
  end
end
