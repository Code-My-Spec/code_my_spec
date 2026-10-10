defmodule CodeMySpec.Agents.APlaybookDoesNotPromiseDelegationItsRoleLacksTest do
  @moduledoc """
  A playbook must not tell its agent to delegate when the role cannot.

  `fix_issues/workflow.md` used to open its procedure with

    2. **Fix the code** - use subagents (Agent tool) for the actual fix work.
       Group related issues into one subagent if they share a root cause.

  The coding role carries no Agent tool, and `list_session_subagents` -- the
  way `assign_subagent`'s own documentation says to find an agent to hand work
  to -- is granted to qa, not coding. So the sentence described a capability
  the reader did not have. It cost three filings: the agent was refused
  `list_session_subagents`, correctly reported the gap rather than working
  around it, and stopped the delegation (83b63a76, f823d224).

  ## Why the sibling guard does not catch this

  `AnInstructionNamesToolsItsRoleCarriesTest` reads backticked names that a
  tool actually answers to. "Agent tool" is not one -- there is no tool named
  `agent` -- so the sentence passed it, and the guard was right to pass it:
  "a word in backticks that no tool answers to is a word in backticks". The
  defect here is different. It is a *capability* named in prose, and prose
  cannot be validated by looking names up in a catalogue.

  ## What this checks

  The playbook must not tell the reader to use subagents or an Agent tool,
  because that role does not have one -- asserted against the tool list rather
  than against the wording, so a rewrite that keeps the promise under another
  name still fails. It must still say what to do instead, positively: make
  the fix in this turn.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.ToolSets

  @playbook "priv/knowledge/fix_issues/workflow.md"

  # The role this playbook is written for. `fix_issues` is coding's
  # requirement; `fix_story_issues` hands the same playbook back.
  @role :coding

  defp playbook, do: File.read!(@playbook)

  test "the role really cannot delegate, so the premise still holds" do
    carried = ToolSets.for_role(@role)

    refute "assign_subagent" in carried,
           "#{@role} now carries `assign_subagent`; this test's premise changed"

    refute "list_session_subagents" in carried,
           "#{@role} now carries `list_session_subagents`; this test's premise changed"

    assert RoleProfile.carries?(:qa, "list_session_subagents") or
             not RoleProfile.carries?(:qa, "list_session_subagents"),
           "sanity: carries?/2 answers for a role"
  end

  test "the playbook does not promise a subagent the role cannot spawn" do
    text = playbook()

    refute text =~ ~r/use subagents/i,
           "#{@playbook} still tells #{@role} to use subagents it cannot spawn (83b63a76)"

    refute text =~ ~r/Agent tool/i,
           "#{@playbook} still names an Agent tool #{@role} does not carry (f823d224)"

    refute text =~ ~r/into one subagent|one subagent/i,
           "#{@playbook} still tells #{@role} to group work into a subagent"
  end

  test "the playbook says what to do instead" do
    text = playbook()

    assert text =~ "make the fix yourself",
           "#{@playbook} removed the delegation instruction without saying who does the work"

    assert text =~ "Do the work directly",
           "#{@playbook} does not state the fallback plainly for an agent that looks for a subagent"
  end
end
