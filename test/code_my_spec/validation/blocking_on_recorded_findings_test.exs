defmodule CodeMySpec.Validation.BlockingOnRecordedFindingsTest do
  @moduledoc """
  A recorded finding blocks the stop.

  Story 988's spex assert this as a *precondition* — "the finding must actually
  block first, or the scenario proves nothing" — and that precondition is what
  fails, before any freshness question is reached. This isolates it away from
  the spex environment so the difference can be seen rather than guessed at.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ProblemsFixtures, UsersFixtures}

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Validation

  @path "lib/my_app/accounts.ex"

  setup do
    # A working copy, because `validate_stop/3` has a `%Scope{cwd: nil}` clause
    # that returns an unconditional allow — no analysis, no blocking check. A
    # test built on `full_scope_fixture/0` alone asserts against that clause and
    # never reaches the decision it means to exercise.
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    Configurations.get_or_create(scope)
    {:ok, _} = Configurations.update(scope, %{credo: :block_all})

    # On disk, not just as a row. `validate_stop/3` syncs the working copy
    # first, so a row with no file behind it is reconciled away before the
    # blocking check ever sees the problem that cites it.
    File.mkdir_p!(Path.join(tmp, "lib/my_app"))
    File.write!(Path.join(tmp, @path), "defmodule MyApp.Accounts do\nend\n")
    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    %{scope: scope}
  end

  test "a credo finding in block_all blocks", %{scope: scope} do
    problem_fixture(scope, %{source: "credo", severity: :error, file_path: @path})
    fresh_analysis_runs_fixture(scope, ["credo"])

    assert {:error, _reason, _key} = Validation.validate_stop(scope, nil),
           "block_all means every finding from this source blocks, and this is the " <>
             "precondition 988's freshness scenarios are built on"
  end

  # The other half: with nothing recorded there is nothing to block on, so a
  # passing assertion above cannot be an artefact of blocking on something else.
  test "no findings means no block", %{scope: scope} do
    fresh_analysis_runs_fixture(scope, ["credo"])

    assert {:ok, _} = Validation.validate_stop(scope, nil)
  end
end
