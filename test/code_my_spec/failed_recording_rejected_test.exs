defmodule CodeMySpecSpex.FailedRecordingRejectedTest do
  @moduledoc """
  A recording whose run did not pass must not be kept.

  `05134805`: a recording session that fails partway through overwrites a
  working cassette with a recording of the failure. Replaying it reproduces that
  failure faithfully, and the file looks like any other cassette — so the next
  reader sees a broken criterion with no sign the breakage lives in the
  recording. Three instances in one night, in three different shapes.

  `refuse_poisoned_cassette/1` was the narrower version of this rule. Its
  reasoning was right and it enumerated provider refusals, so a step that
  errored for another reason, a non-zero exit from a shelled-out tool, and a
  poll that ran to exhaustion were all kept. The stronger rule needs no
  enumeration: if the block raised, the run did not pass.

  Driven through `with_provider_cassette/3` with a block that raises, against a
  temp cassette directory — the real function on the real path, rather than a
  reimplementation of the rename.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  defp cassette(dir, name), do: Path.join(dir, name <> ".json")

  defp record(dir, name, fun) do
    CodeMySpecSpex.Case.with_provider_cassette(
      name,
      [mode: :record, cassette_dir: dir],
      fun
    )
  end

  describe "a recording whose run failed" do
    # The block writes before raising, which is what a real failing recording
    # does: instance 1 of the issue left 353 KB of failed verification polls and
    # 3.3 MB of fruitless receive polls on disk. A block that raises without
    # making a request writes nothing, so there is no artifact to reject — safe,
    # but not the case this guard exists for.
    test "is set aside as .rejected rather than kept", %{tmp_dir: dir} do
      name = "failed_run_#{System.unique_integer([:positive])}"
      path = cassette(dir, name)

      capture_io(:stderr, fn ->
        assert_raise RuntimeError, "the step failed", fn ->
          record(dir, name, fn ->
            File.write!(path, ~s({"interactions": ["the failed polls"]}))
            raise "the step failed"
          end)
        end
      end)

      assert File.exists?(path <> ".rejected"),
             "the failed recording should be kept as .rejected, not deleted"

      assert File.read!(path <> ".rejected") =~ "the failed polls"

      refute File.exists?(path),
             "a recording of a failed run was left armed, and would replay as " <>
               "the criterion's expected behaviour"
    end

    test "restores the working cassette the run set aside", %{tmp_dir: dir} do
      name = "restores_bak_#{System.unique_integer([:positive])}"
      path = cassette(dir, name)
      File.write!(path, ~s({"interactions": ["the good recording"]}))

      capture_io(:stderr, fn ->
        assert_raise RuntimeError, fn ->
          record(dir, name, fn ->
            File.write!(path, ~s({"interactions": ["the failed polls"]}))
            raise "boom"
          end)
        end
      end)

      # `clear_cassette_once/2` renamed the working cassette to `.bak` on entry.
      # Instance 1 of the issue was two cassettes lost this way, recovered only
      # because a human noticed and restored the .bak by hand.
      assert File.exists?(path), "the previous working cassette was not restored"
      assert File.read!(path) =~ "the good recording"
      assert File.read!(path <> ".rejected") =~ "the failed polls"
    end

    test "says why, and where the evidence went", %{tmp_dir: dir} do
      name = "explains_#{System.unique_integer([:positive])}"
      File.write!(cassette(dir, name), ~s({"interactions": []}))

      output =
        capture_io(:stderr, fn ->
          assert_raise RuntimeError, fn -> record(dir, name, fn -> raise "boom" end) end
        end)

      assert output =~ "did not pass"
      assert output =~ ".rejected"
    end

    # The failure has to keep travelling — this guard cleans up after a failing
    # run, it does not absorb it. Swallowing the exception would turn a red spex
    # green while quietly discarding its cassette.
    test "still fails the run", %{tmp_dir: dir} do
      name = "reraises_#{System.unique_integer([:positive])}"
      File.write!(cassette(dir, name), ~s({"interactions": []}))

      capture_io(:stderr, fn ->
        assert_raise ArgumentError, "the original error", fn ->
          record(dir, name, fn -> raise ArgumentError, "the original error" end)
        end
      end)
    end
  end

  describe "replay" do
    # Nothing is being written, so there is no artifact to poison — and a
    # failing replay is a finding about the code, which must not delete the
    # cassette that produced it.
    test "is untouched by a failing run", %{tmp_dir: dir} do
      name = "replay_#{System.unique_integer([:positive])}"
      path = cassette(dir, name)
      File.write!(path, ~s({"http_interactions": []}))

      assert_raise RuntimeError, fn ->
        CodeMySpecSpex.Case.with_provider_cassette(
          name,
          [mode: :replay, cassette_dir: dir],
          fn -> raise "boom" end
        )
      end

      assert File.exists?(path), "a failing replay must not remove the cassette"
      refute File.exists?(path <> ".rejected")
    end
  end
end
