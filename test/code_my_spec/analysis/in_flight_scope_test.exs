defmodule CodeMySpec.Analysis.InFlightScopeTest do
  @moduledoc """
  "A rerun is in flight" has to mean *this* working copy's rerun.

  `running_sources/1` filtered on `project_id` alone while every other query in
  the repository went through `scope_to_harness/2`. Two checkouts of one project
  are two working copies with two toolchains and two `_build`s, so another
  copy's spex sweep produces nothing for this one — and the stop hook turns that
  answer directly into advice.

  Observed: three consecutive blocked stops told an agent "a rerun is in flight
  now — stop again and let it replace these" while its own last completed run
  sat 96 minutes back and its requested rerun had been dropped. The in-flight
  runs belonged to a different checkout. The correct advice was the opposite of
  what it got, and waiting could never have produced a result.

  Scoping is a no-op when the scope carries no harness — the working-directory
  fallback path — which is deliberate here: that widening is its own problem
  and narrowing it silently would hide the identity gap rather than fix it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    {:ok, mine} =
      WorkingCopies.issue(scope, nil, label: "this working copy", device: device_fixture(scope))

    {:ok, theirs} =
      WorkingCopies.issue(scope, nil, label: "another checkout", device: device_fixture(scope))

    %{
      scope: %{scope | active_working_copy_id: mine.id},
      mine: mine.id,
      theirs: theirs.id
    }
  end

  # `start_run/2` stamps `working_copy_id` from the scope rather than the attrs, so
  # a run belonging to another checkout is made by handing it that checkout's
  # scope — the same way the other checkout's own harness would.
  defp start_run(scope, source, working_copy_id) do
    {:ok, run} =
      RunsRepository.start_run(%{scope | active_working_copy_id: working_copy_id}, %{
        source: source,
        kind: :full
      })

    run
  end

  test "another checkout's running sweep is not this copy's rerun", ctx do
    start_run(ctx.scope, "spex", ctx.theirs)

    assert RunsRepository.running_sources(ctx.scope) == [],
           "a sweep on another working copy produces no result for this one, so " <>
             "reporting it as in flight tells the agent to wait for something " <>
             "that will never arrive"
  end

  test "this copy's own running sweep is reported", ctx do
    start_run(ctx.scope, "spex", ctx.mine)

    assert RunsRepository.running_sources(ctx.scope) == ["spex"]
  end

  test "with both running, only this copy's is reported", ctx do
    start_run(ctx.scope, "spex", ctx.theirs)
    start_run(ctx.scope, "exunit", ctx.mine)

    assert RunsRepository.running_sources(ctx.scope) == ["exunit"]
  end

  test "a scope with no harness still sees the project's runs", ctx do
    start_run(ctx.scope, "spex", ctx.theirs)
    unscoped = %{ctx.scope | active_working_copy_id: nil}

    assert RunsRepository.running_sources(unscoped) == ["spex"],
           "the working-directory fallback has no harness to filter by; " <>
             "narrowing it to nothing here would turn one gap into two"
  end
end
