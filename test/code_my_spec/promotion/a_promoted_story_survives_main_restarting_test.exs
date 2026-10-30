defmodule CodeMySpec.Promotion.APromotedStorySurvivesMainRestartingTest do
  @moduledoc """
  ccedd2e7: `story_promoted` asked whether main was serving as well as whether
  the story carried a stamp, so each restart of main after a promote flipped
  every promoted story to unsatisfied. Work handed the first to a coder, who
  ran the full gate and changed nothing — 26 times from 09-27 to 10-01.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Promotion.RunningCopy
  alias CodeMySpec.Staffing
  alias CodeMySpec.WorkingCopies

  def count_owner_query(_, _, _, {owner, counter}) when self() == owner do
    :counters.add(counter, 1, 1)
  end

  def count_owner_query(_, _, _, _), do: :ok

  defp main_copy(scope, status) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, copy} = Staffing.designate_main(scope, copy.id)
    {:ok, _instance} = WorkingCopies.record_preview_status(copy, status)
    copy
  end

  test "a stamped story stays promoted while main is down" do
    scope = full_scope_fixture()
    main_copy(scope, "down")

    {_unpromoted, promoted} =
      RunningCopy.running_copy_verdicts(scope, [%{id: 50, promoted_version: "0.1.1"}])

    assert {true, %{status: "Promoted at version 0.1.1"}} = promoted[50],
           "main restarting un-promoted a story whose code it already holds"
  end

  test "checking many stamped stories has a fixed query cost" do
    scope = full_scope_fixture()
    main_copy(scope, "serving")
    stories = for id <- 1..12, do: %{id: id, promoted_version: "0.1.1"}

    owner = self()
    counter = :counters.new(1, [])
    handler = {__MODULE__, owner, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:code_my_spec, :repo, :query],
        &__MODULE__.count_owner_query/4,
        {owner, counter}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {_unpromoted, promoted} = RunningCopy.running_copy_verdicts(scope, stories)

    assert map_size(promoted) == 12
    assert Enum.all?(promoted, fn {_id, {satisfied?, _details}} -> satisfied? end)
    assert :counters.get(counter, 1) <= 3
  end

  test "a new QA revision is unpromoted even with an older publication stamp" do
    scope = full_scope_fixture()
    main_copy(scope, "serving")

    story = %{
      id: 50,
      promoted_version: "0.1.1",
      promoted_candidate_commit: "old-candidate",
      promoted_qa_commit: "old-qa",
      qa_ready_commit: "new-qa"
    }

    {_unpromoted, promoted} = RunningCopy.running_copy_verdicts(scope, [story])
    assert {false, %{reason: reason}} = promoted[50]
    assert reason =~ "new-qa has no tracked publication"
    assert RunningCopy.running_copy_check(scope, story) == promoted[50]
  end

  test "an unstamped story is still unpromoted" do
    scope = full_scope_fixture()
    main_copy(scope, "serving")

    {unpromoted, _promoted} = RunningCopy.running_copy_verdicts(scope, [])

    assert {false, %{promoted: false}} = unpromoted
  end

  test "a stamped story on main stays promoted while its preview is down" do
    scope = full_scope_fixture()
    main = main_copy(scope, "down")
    scope = %{scope | active_working_copy_id: main.id}

    assert {true, %{status: "Promoted at version 0.1.1"}} =
             RunningCopy.running_copy_check(scope, %{promoted_version: "0.1.1"})
  end

  test "working on main still requires remote publication" do
    scope = full_scope_fixture()
    main = main_copy(scope, "serving")
    scope = %{scope | active_working_copy_id: main.id}

    assert {false, %{promoted: false}} =
             RunningCopy.running_copy_check(scope, %{promoted_version: nil})
  end
end
