defmodule CodeMySpec.Analysis.FreshnessTest do
  @moduledoc """
  What decides whether a source is fresh.

  Two things could make a good answer read as stale, and both were live:

  1. **Another checkout's run.** `latest_full_run/2` filtered by project only,
     and a project has a worktree per branch. So the newest run of *any* copy
     answered the question, and its fingerprint is computed over different
     files — a source could not be fresh while another agent worked.
     `acde83fd` scoped the lookup on submit and the sweep on join, and missed
     this one.

  2. **A run that never ran.** The query included `:failed`, and `fresh?/2`
     requires `:completed`, so the newest failure read as stale regardless of
     the good result behind it. A duplicate enqueue refused as "already queued"
     is exactly that: 14 such rows in half an hour on this machine, each one
     marking its source stale.

  Together these are most of why a source could be reported "stale, last ran 0s
  ago" — a contradiction the stop hook printed verbatim.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.WorkingCopies

  defp run(scope, attrs) do
    {:ok, r} =
      RunsRepository.start_run(scope, Map.merge(%{source: "credo", kind: :full}, attrs))

    r
  end

  defp finish(run, status), do: RunsRepository.finish_run(run, status, %{})

  test "another checkout's run does not answer for mine" do
    mine = full_scope_fixture()

    {:ok, other} =
      WorkingCopies.issue(mine, nil, label: "a second checkout", device: device_fixture(mine))

    theirs = %{mine | active_working_copy_id: other.id}

    theirs |> run(%{input_fingerprint: "theirs"}) |> finish(:completed)

    refute RunsRepository.latest_completed_run(mine, "credo"),
           "freshness is a question about one working copy's tree; another " <>
             "copy's fingerprint is computed over different files"

    assert RunsRepository.latest_completed_run(theirs, "credo")
  end

  test "a later failure does not unseat the answer behind it" do
    scope = full_scope_fixture()

    scope |> run(%{input_fingerprint: "good"}) |> finish(:completed)
    scope |> run(%{input_fingerprint: "refused"}) |> finish(:failed)

    assert %{input_fingerprint: "good"} = RunsRepository.latest_completed_run(scope, "credo"),
           "a duplicate enqueue refused as 'already queued' is a scheduling " <>
             "fact, and must not invalidate a result that exists"
  end

  test "the latest completed run is the newest one" do
    scope = full_scope_fixture()

    scope |> run(%{input_fingerprint: "older"}) |> finish(:completed)
    scope |> run(%{input_fingerprint: "newer"}) |> finish(:completed)

    assert %{input_fingerprint: "newer"} = RunsRepository.latest_completed_run(scope, "credo")
  end

  test "no completed run at all is nil rather than a failure" do
    scope = full_scope_fixture()
    scope |> run(%{input_fingerprint: "x"}) |> finish(:failed)

    refute RunsRepository.latest_completed_run(scope, "credo")
  end
end
