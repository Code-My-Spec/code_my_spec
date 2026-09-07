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
    fresh_analysis_runs_fixture(scope)

    assert {:error, _reason, _key} = Validation.validate_stop(scope, nil),
           "block_all means every finding from this source blocks, and this is the " <>
             "precondition 988's freshness scenarios are built on"
  end

  # The other half: with nothing recorded there is nothing to block on, so a
  # passing assertion above cannot be an artefact of blocking on something else.
  test "no findings means no block", %{scope: scope} do
    fresh_analysis_runs_fixture(scope)

    assert {:ok, _} = Validation.validate_stop(scope, nil)
  end

  # The path a spex takes, which is not the one above.
  #
  # `Problems.create_problems/2` stamps `file_fingerprint` from the file as it
  # stands at insert, and `reject_superseded/1` drops any finding whose file has
  # moved on since. That is the point of both — a finding about bytes that no
  # longer exist is not evidence about the bytes that do.
  #
  # It also means a scenario that records a finding and *then* touches the file
  # loses it, which reads as "the finding did not block" rather than "the
  # finding was superseded". 988's scenarios record and then re-sync.
  describe "a finding recorded the way the pipeline records them" do
    test "blocks while its file is unchanged", %{scope: scope} do
      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            source: "credo",
            severity: :error,
            message: "nesting too deep",
            file_path: @path,
            category: "readability",
            line: 61
          }
        ])

      fresh_analysis_runs_fixture(scope)

      assert {:error, _reason, _key} = Validation.validate_stop(scope, nil)
    end

    test "is superseded once the file moves on", %{scope: scope} do
      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            source: "credo",
            severity: :error,
            message: "nesting too deep",
            file_path: @path,
            category: "readability",
            line: 61
          }
        ])

      File.write!(Path.join(scope.cwd, @path), "defmodule MyApp.Accounts do\n  # edited\nend\n")
      {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)
      fresh_analysis_runs_fixture(scope)

      assert {:ok, _} = Validation.validate_stop(scope, nil),
             "the finding cites bytes that no longer exist, so it is superseded — " <>
               "which is correct, and is why a scenario that records then edits " <>
               "sees no block and reads it as the rule failing"
    end
  end
end
