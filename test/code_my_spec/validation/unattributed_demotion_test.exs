defmodule CodeMySpec.Validation.UnattributedDemotionTest do
  @moduledoc """
  Task evaluation judges the whole copy, so attribution demotes nothing.

  This file used to assert the opposite: that a finding in a file the session
  did not edit was demoted to advisory. The reasoning was real — several agents
  share this repo and rebase onto main, so a warning one pushes became a hard
  block on every other's stop (`7a0fadeb`, `d3fa4dc1`), and the only compliant
  responses to a rebase's worth of findings were to break someone else's code or
  stay blocked.

  John, 2026-10-04 (issue 48f4eada), retired that rule: task evaluation judges
  the whole copy, the same way promotion does. v2.0.347 made credo's default
  `block_all`, but the attribution excuse still demoted every finding in a file
  the session hadn't edited, which made task evaluation changed-files-only for
  any agent that edited anything — whole-copy applied only when there was no
  attribution at all. So the excuse is gone and `split_unattributed/2` now
  keeps everything blocking.

  The old rule's incidents (`a9e9caca`, `042e343b`, `d91436b7`) are answered
  elsewhere now: `split_by_story_enforcement/3` asks "is this red mine to fix"
  from the owning story's latch, and `split_by_role/2` reads the role profile.
  Both still run; neither is attribution.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Validation

  defp problem(path) do
    %CodeMySpec.Problems.Problem{
      source: "compiler",
      severity: :error,
      file_path: path,
      line: 1,
      message: "something",
      category: "warning"
    }
  end

  describe "with a known set of this session's edits" do
    test "a finding in a file the session edited keeps blocking" do
      mine = problem("lib/mine.ex")

      assert {[^mine], []} =
               Validation.split_unattributed([mine], MapSet.new(["lib/mine.ex"]))
    end

    test "a finding in a file the session never edited blocks too" do
      # Was demoted. Whole-copy means whole copy: a warning that arrived with a
      # rebase is still a warning in this working copy, and task evaluation
      # judges the copy.
      theirs = problem("lib/theirs.ex")

      assert {[^theirs], []} =
               Validation.split_unattributed([theirs], MapSet.new(["lib/mine.ex"]))
    end

    test "a finding with no file at all keeps blocking" do
      # A spex that died in setup_all has no file to attribute. Nothing can be
      # concluded from that, so it blocks.
      orphan = problem(nil)

      assert {[^orphan], []} =
               Validation.split_unattributed([orphan], MapSet.new(["lib/mine.ex"]))
    end
  end

  describe "when the session wrote nothing" do
    test "an empty set demotes nothing" do
      # The property that matters most: an empty set is not evidence that the
      # findings are somebody else's. Previously this demoted every finding
      # naming a file, which is how the gate quietly stopped blocking — if
      # attribution goes empty for any reason that is not "wrote nothing",
      # everything looks unattributed.
      theirs = problem("lib/theirs.ex")

      assert {[^theirs], []} = Validation.split_unattributed([theirs], MapSet.new())
    end

    test "a finding with no file is not demoted either" do
      orphan = problem(nil)

      assert {[^orphan], []} = Validation.split_unattributed([orphan], MapSet.new())
    end

    test "spex is not demoted" do
      spex = %{problem("test/spex/a_spex.exs") | source: "spex"}

      assert {[^spex], []} = Validation.split_unattributed([spex], MapSet.new())
    end
  end

  describe "when the session did edit" do
    test "spex blocks whatever the session touched" do
      spex = %{problem("test/spex/a_spex.exs") | source: "spex"}

      assert {[^spex], []} =
               Validation.split_unattributed([spex], MapSet.new(["lib/unrelated.ex"]))
    end
  end

  describe "when attribution cannot be trusted" do
    test "nil demotes nothing" do
      theirs = problem("lib/theirs.ex")

      assert {[^theirs], []} = Validation.split_unattributed([theirs], nil)
    end
  end

  test "order is preserved" do
    a = problem("lib/mine.ex")
    b = problem("lib/theirs.ex")
    c = problem("lib/mine2.ex")

    assert {[^a, ^b, ^c], []} =
             Validation.split_unattributed([a, b, c], MapSet.new(["lib/mine.ex", "lib/mine2.ex"]))
  end
end
