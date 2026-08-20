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

    test "a finding with no file is demoted too, because nothing is this agent's" do
      # This asserted the opposite until story 894's rule — "an agent that made
      # no edits is blocked by nothing" — was written down, on the reasoning
      # that "unattributable is not the same as somebody else's: a spex that
      # died in `setup_all` has nothing to attribute, and demoting it drops the
      # finding nobody can place."
      #
      # That reasoning still holds, and nothing is dropped: a finding with no
      # file is unattributable, so it blocks *every* session that recorded an
      # edit — see the `attributable_to?/2` clause below. What changed is only
      # who carries it, and a session that wrote nothing cannot have caused it.
      # The next agent to touch anything is still stopped by it.
      orphan = problem(nil)

      assert {[], [^orphan]} = Validation.split_unattributed([orphan], MapSet.new())
    end

    test "a finding with no file still blocks a session that did edit" do
      # The other half of the trade above, pinned so the demotion cannot widen
      # into "unattributable findings are advisory".
      orphan = problem(nil)

      assert {[^orphan], []} =
               Validation.split_unattributed([orphan], MapSet.new(["lib/mine.ex"]))
    end

    test "spex is demoted too — a session that wrote nothing owns no red" do
      # This asserted the opposite, on reasoning worth keeping: "
      # `split_by_story_enforcement/3` already answered 'is this red mine to
      # fix' from the owning story's latch. Letting attribution answer it again
      # is what turned `spex: :block_all` into a no-op for months."
      #
      # It is still not a no-op. Attribution only overrides the latch for a
      # session that recorded no edits at all; every session that touched
      # anything still gets spex regardless of which files it touched, which is
      # the property that reasoning was defending — see the test below.
      #
      # The case that forced the carve-out, a9e9caca: a QA session with a
      # provably empty `git status` was refused a stop over 26 spex failures in
      # three unrelated stories, all last touched days earlier by someone else.
      # QA sessions hit it every time, because their artifacts live under
      # `.code_my_spec/qa/`, which git ignores — so real work leaves no tracked
      # edit and the agent is handed the whole project's red.
      spex = %{problem("test/spex/a_spex.exs") | source: "spex"}

      assert {[], [^spex]} = Validation.split_unattributed([spex], MapSet.new())
    end
  end

  describe "when the session did edit" do
    # What the story-894 carve-out must not become. A session that touched
    # anything still gets every spex failure, whatever files it touched — the
    # latch decides that upstream, and attribution must not second-guess it.
    test "spex blocks whatever the session touched" do
      spex = %{problem("test/spex/a_spex.exs") | source: "spex"}

      assert {[^spex], []} =
               Validation.split_unattributed([spex], MapSet.new(["lib/unrelated.ex"]))
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
