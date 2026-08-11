defmodule CodeMySpec.Hooks.StopBlockingSummaryTest do
  @moduledoc """
  The field that makes stop decisions aggregatable across agents.

  Asking "where does an onboarding agent get stuck" means grouping stops by
  what blocked them, and the hook's own log line could not answer it: the
  reason was truncated to 100 characters of prose, so two agents blocked on
  entirely different things produced lines that only differed after the cut.

  `cms_blocking` carries `exunit=1,credo=6` instead. These pin the parse
  against the shapes `Validation` actually emits, because the summary is read
  back out of the reason text — if that header changes, this is where it shows.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Hooks.Stop

  describe "blocking_summary/1" do
    test "names each source and its count" do
      reason = """
      Fix these problems before stopping:

      exunit (2):
        - test/foo_test.exs:12 — it broke

      credo (6):
        - lib/bar.ex:3 — imperative if
      """

      assert Stop.blocking_summary(reason) == "exunit=2,credo=6"
    end

    test "a single source is the whole summary" do
      assert Stop.blocking_summary("Fix these problems before stopping:\n\nspex (60):\n  - x") ==
               "spex=60"
    end

    # The advisory block names sources too, and they are equally worth counting:
    # a source that is advisory today is the one an agent ignores until it is
    # not. The parse does not distinguish them, and the counts are what matter.
    test "advisory sources are counted alongside blocking ones" do
      reason = """
      exunit (1):
        - broke

      Additional problems (not blocking):
        - credo: 534 infos (advisory)
      """

      assert Stop.blocking_summary(reason) =~ "exunit=1"
    end

    test "a reason with no source header summarises to nothing" do
      assert Stop.blocking_summary("Something went wrong, but not like that") == ""
    end

    test "a non-binary reason does not raise" do
      assert Stop.blocking_summary(nil) == ""
    end

    # Guards the direction that matters. A wrong summary is worse than an empty
    # one: it would group an agent's stops under a source that never blocked
    # them, and the whole point is deciding where to spend repair effort.
    test "prose that merely resembles the header is not counted" do
      assert Stop.blocking_summary("the analyzer (2) ran") == ""
    end
  end
end
