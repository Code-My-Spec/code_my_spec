defmodule CodeMySpec.Agents.TheSpecWriterWorksThroughEverySpecInOneTurnTest do
  @moduledoc """
  Writing and validating one spec is a step inside the turn, not the end of it.

  The bdd-spec-writer agent definition used to end its workflow with

    8. **Stop and report** - return for validation before writing the next spec

  and "Write ONE spec file at a time, then stop for validation" under
  Important. A Codex coder read the per-spec validation line as a stopping
  point and ended its turn after every spec, paying a turn boundary and a
  re-offer for each one instead of writing the remaining criteria
  (5ed5d134).

  The instruction is authored here, in the two agent definitions the plugins
  ship, and nothing else in the repository contains it -- so this reads those
  files rather than a prompt built at run time.

  ## What this checks

  The definition must still say one file at a time -- that part was right, and
  it is what keeps a single spec reviewable -- and it must say the turn
  continues to the next criterion rather than that it stops after this one.

  A test that only checked for the absence of the old sentence would pass on a
  file with no instruction at all, so the continuation is asserted positively
  and the stopping words are asserted absent.
  """

  use ExUnit.Case, async: true

  @definitions [
    "plugins/claude/agents/bdd-spec-writer.md",
    "plugins/antigravity/agents/bdd-spec-writer/agent.md"
  ]

  defp source(path), do: File.read!(path)

  test "each definition tells the writer to continue to the next criterion" do
    for path <- @definitions do
      text = source(path)

      assert text =~ "ONE spec file",
             "#{path} no longer says to write one spec file at a time"

      assert text =~ "continue to the next one in the same turn" or
               text =~ "Continue to the next criterion in this same turn",
             "#{path} does not say the turn continues past the spec it just wrote"

      assert text =~ "the turn ends when all missing criteria are covered" or
               text =~ "End the turn only when every missing",
             "#{path} does not say where the turn actually ends"
    end
  end

  test "no definition tells the writer to stop after validating one spec" do
    for path <- @definitions do
      text = source(path)

      refute text =~ "return for validation before writing the next spec",
             "#{path} still ends the turn after a single spec (5ed5d134)"

      refute text =~ "then stop for validation",
             "#{path} still reads a single spec's validation as a stopping point"

      refute text =~ "Do not write multiple spec files in a single pass",
             "#{path} still forbids covering the remaining criteria in the turn"
    end
  end

  # The floor. Both checks above can be satisfied by a definition that stopped
  # saying anything about how the work is sequenced -- a file rewritten by
  # somebody who did not know why the sentence was there. This says the two
  # halves the instruction is made of are still both present.
  test "the instruction is still about sequencing, not just about writing a file" do
    for path <- @definitions do
      text = source(path)

      assert text =~ "Run `mix compile`",
             "#{path} no longer tells the writer to compile what it just wrote"

      assert text =~ ~r/[Tt]urn/,
             "#{path} no longer mentions the turn at all, so nothing here is a sequence"
    end
  end
end
