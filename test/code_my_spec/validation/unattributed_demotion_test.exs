defmodule CodeMySpec.Validation.UnattributedDemotionTest do
  @moduledoc """
  The gate blocks on this session's work, not on what arrived with a rebase.

  Several agents share this repo and rebase onto main, so a warning one pushes
  became a hard block on every other's stop. Reported three times: compiler
  warnings from another branch's in-flight file (`7a0fadeb`), spex failures
  eight days older than the session (`d3fa4dc1`), and credo infos recorded two
  days before the file was opened.

  The trap is not the noise. In `7a0fadeb` the obvious repair — deleting an
  unused `@endpoint` — silently retargets a preview spex at the wrong endpoint,
  because `use CodeMySpecSpex.Case` sets one and the story overrides it on
  purpose. So the only compliant responses were to break someone else's code or
  stay blocked.

  Demotion is the half that can fail dangerously: if attribution goes empty for
  a reason that is not "wrote nothing", everything looks unattributed and the
  gate quietly stops blocking. So the guards here are the assertions that
  matter most — an unknown answer keeps blocking, and only a positive
  attribution can demote anything.
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

    test "a finding in a file the session never edited is demoted" do
      theirs = problem("lib/theirs.ex")

      assert {[], [^theirs]} =
               Validation.split_unattributed([theirs], MapSet.new(["lib/mine.ex"]))
    end

    test "a finding with no file at all keeps blocking" do
      # A spex that died in setup_all has no file to attribute. That is
      # unattributable, not somebody else's, and the two must not collapse —
      # demoting it would silently drop the one finding nobody can place.
      orphan = problem(nil)

      assert {[^orphan], []} =
               Validation.split_unattributed([orphan], MapSet.new(["lib/mine.ex"]))
    end
  end

  describe "when attribution cannot be trusted" do
    test "an empty set demotes nothing" do
      # "The session wrote nothing" and "attribution broke" look identical from
      # here — a restart, or a path shape that did not normalize. Demoting on
      # the second reading switches the gate off and says nothing.
      theirs = problem("lib/theirs.ex")

      assert {[^theirs], []} = Validation.split_unattributed([theirs], MapSet.new())
    end

    test "nil demotes nothing" do
      theirs = problem("lib/theirs.ex")

      assert {[^theirs], []} = Validation.split_unattributed([theirs], nil)
    end
  end

  test "order within each side is preserved" do
    a = problem("lib/mine.ex")
    b = problem("lib/theirs.ex")
    c = problem("lib/mine2.ex")

    assert {[^a, ^c], [^b]} =
             Validation.split_unattributed([a, b, c], MapSet.new(["lib/mine.ex", "lib/mine2.ex"]))
  end
end
