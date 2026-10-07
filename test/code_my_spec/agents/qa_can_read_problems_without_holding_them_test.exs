defmodule CodeMySpec.Agents.QaCanReadProblemsWithoutHoldingThemTest do
  @moduledoc """
  QA may inspect problems; it is still never held open by them.

  Issue `930d9c47`. A user directed QA to check Spex, and the agent could not:
  `list_problems` is not a tool a qa agent carries. That refusal is deliberate
  in one half and wrong in the other, and the two halves were carried by one
  grant.

    * `holds_problems?` is `false` for qa on purpose. A QA agent was once held
      open by the project's 47 Spex findings, could not read them, could not
      fix them, and could not stop. That has to stay.
    * Reading them is a different thing. QA is directed at Spex failures during
      a QA pass and needs to see what they are, to report them and to tell a
      real defect from a broken tree. That is a read, and it is not the
      capability the agent above was missing -- its problem was having no move,
      which `holds_problems?` is what decides.

  So qa gains `list_problems` and keeps `clear_problems` off: it can see, and
  it still cannot clear, and it is still not held open. Asserted on both, so a
  later change that grants the write or flips `holds_problems?` fails here.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.ToolSets

  test "qa may read problems" do
    assert "list_problems" in ToolSets.for_role(:qa),
           "a qa agent directed at Spex failures has to be able to list them"
  end

  test "qa still may not clear them" do
    refute "clear_problems" in ToolSets.for_role(:qa),
           "clearing problems is coding's; granting it here is a different decision"
  end

  test "qa is still not held open by problems" do
    refute RoleProfile.holds_problems?(:qa),
           "the whole point of the refusal was that a qa agent with no move to " <>
             "clear a finding must not be held open by it"
  end

  test "coding still holds and can clear them" do
    assert RoleProfile.holds_problems?(:coding)
    assert "clear_problems" in ToolSets.for_role(:coding)
    assert "list_problems" in ToolSets.for_role(:coding)
  end
end
