defmodule CodeMySpec.Analysis.ARunNamesTheDatabaseItUsedTest do
  @moduledoc """
  A test-suite result carries which database answered, and the problem list says
  so.

  A working copy has three test databases — the interactive session's, the
  analyzer's exunit partition, and its spex partition — and a run uses exactly
  one. Nothing recorded which, and twice that made a database problem read as a
  code problem with every available signal agreeing:

    * 479 spex failures, all `column q0.resolution does not exist`, against a
      tree whose migration was written, committed and applied. The partition was
      five days behind the base (`d86b09cd`). Four confident wrong diagnoses
      before anyone compared databases.
    * a criterion that passed sixteen consecutive runs in isolation and failed
      every analyzer sweep, because `working_copies_device_id_fkey` was
      `ON DELETE CASCADE` on the base and `ON DELETE RESTRICT` on the spex
      partition. Three promotion refusals before anybody asked which database
      had answered (`9d4ae2de`).

  Recorded on the run rather than on each problem: it is one fact per run, and a
  per-problem copy would have been four hundred identical strings.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Runners

  describe "from_raw/2" do
    test "exunit keeps the partition the harness reported" do
      raw = %{
        "execution_status" => "completed",
        "exit_status" => 1,
        "output" => "",
        "stats" => %{"tests" => 12, "failures" => 1},
        "partition" => "h789652afa",
        "diagnostics" => [
          %{"file" => "test/foo_test.exs", "line" => 3, "message" => "boom"}
        ]
      }

      assert {:ok, result} = Runners.from_raw("exunit", raw)
      assert result.stats["partition"] == "h789652afa"

      assert result.stats["tests"] == 12,
             "the partition is added to the harness's stats, not substituted for them"
    end

    test "spex keeps it too" do
      raw = %{
        "exit_status" => 1,
        "output" => "",
        "partition" => "h789652afs",
        "diagnostics" => [
          %{
            "file" => "test/spex/x_spex.exs",
            "line" => 9,
            "spex" => "a thing",
            "scenario" => "a case",
            "message" => "boom"
          }
        ]
      }

      assert {:ok, result} = Runners.from_raw("spex", raw)
      assert result.stats["partition"] == "h789652afs"
    end

    # The compiler and credo read files rather than opening a connection, so a
    # partition on their findings would be a true fact about an irrelevant
    # thing — and a reader who takes it as relevant is worse off than one who
    # was told nothing.
    test "credo carries none, because it opens no database" do
      raw = %{"exit_status" => 0, "diagnostics" => []}

      assert {:ok, result} = Runners.from_raw("credo", raw)
      refute Map.has_key?(result.stats, "partition")
    end

    # An older harness sends no such key. The run records no partition rather
    # than a guessed one — inventing a database name here would be the same
    # failure this exists to end, one level up.
    test "a payload without the key records no partition rather than a guess" do
      raw = %{
        "execution_status" => "completed",
        "exit_status" => 0,
        "output" => "",
        "stats" => %{"tests" => 3},
        "diagnostics" => []
      }

      assert {:ok, result} = Runners.from_raw("exunit", raw)
      refute Map.has_key?(result.stats, "partition")
    end

    test "an empty partition is not recorded" do
      raw = %{
        "execution_status" => "completed",
        "exit_status" => 0,
        "output" => "",
        "stats" => %{},
        "partition" => "",
        "diagnostics" => []
      }

      assert {:ok, result} = Runners.from_raw("exunit", raw)
      refute Map.has_key?(result.stats, "partition")
    end
  end
end
