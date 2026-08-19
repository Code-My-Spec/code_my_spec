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

  describe "when the session wrote nothing" do
    test "an empty set demotes every finding that names a file" do
      # Was "an empty set demotes nothing", on the reasoning that "the session
      # wrote nothing" and "attribution broke" look identical from here. They no
      # longer arrive here as the same value: `verify_against_ledger/3` answers
      # `nil` for the broken case specifically, so what is left when a set is
      # merely empty is a session that edited nothing — and one that edited
      # nothing cannot own a finding in a file.
      #
      # 76008385: a QA agent writes no project files by nature, so it hit this
      # on every stop and every finding blocked, with no action available that
      # would change the answer.
      theirs = problem("lib/theirs.ex")

      assert {[], [^theirs]} = Validation.split_unattributed([theirs], MapSet.new())
    end

    test "a finding with no file still blocks, even then" do
      # Unattributable is not the same as somebody else's. A spex that died in
      # `setup_all` has nothing to attribute, and demoting it drops the finding
      # nobody can place.
      orphan = problem(nil)

      assert {[^orphan], []} = Validation.split_unattributed([orphan], MapSet.new())
    end

    test "spex still blocks, because its mandate was decided upstream" do
      # `split_by_story_enforcement/3` already answered "is this red mine to
      # fix" from the owning story's latch. Letting attribution answer it again
      # is what turned `spex: :block_all` into a no-op for months.
      spex = %{problem("test/spex/a_spex.exs") | source: "spex"}

      assert {[^spex], []} = Validation.split_unattributed([spex], MapSet.new())
    end
  end

  describe "when attribution cannot be trusted" do
    test "nil demotes nothing" do
      # Distinct from the empty set above, and the distinction is the whole
      # point: `nil` means attribution is *unusable* — no session id, or
      # recorded paths that join no File row in this project. Nothing can be
      # concluded from a set that means nothing, so everything blocks.
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
