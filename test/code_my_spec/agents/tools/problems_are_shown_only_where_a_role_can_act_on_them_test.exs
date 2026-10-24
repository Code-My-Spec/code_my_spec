defmodule CodeMySpec.Agents.Tools.ProblemsAreShownOnlyWhereARoleCanActOnThemTest do
  @moduledoc """
  7333963c: `list_agent_work` printed "problems on this copy: N" under every
  agent on a checkout, including a role that can do nothing about them
  (`RoleProfile.holds_problems?/1` is false) -- an idle QA agent next to a
  real compiler failure read as ignoring a backlog that was never its to
  clear.

  A problem belongs to the working copy, not to whichever agent happens to be
  on it (same family as 4849f20b). Detail is shown only under an agent whose
  role can act on it; a copy with nobody present who can gets a project-wide
  note instead, once, so the count still reaches whoever reads this.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Tools.AgentWorkResponses, as: AgentWorkMapper

  defp agent(id, role, opts) do
    %AgentWork{
      agent_id: id,
      role: role,
      agent_status: :running,
      working_copy_id: Keyword.get(opts, :working_copy_id, "copy-#{id}"),
      working_copy_root: Keyword.get(opts, :working_copy_root),
      problems: Keyword.get(opts, :problems, [])
    }
  end

  @finding %{
    source: "compiler",
    file_path: "lib/my_app/refunds.ex",
    line: 12,
    message: "redefining @doc"
  }

  test "a role that cannot act on problems does not get them attributed to it, and the copy's count still surfaces" do
    work = [agent("qa-id", :qa, working_copy_id: "copy-a", problems: [@finding])]

    text = AgentWorkMapper.text(work)

    refute text =~ "redefining @doc",
           "the finding itself must not be printed against a role that cannot act on it: #{text}"

    refute text =~ "problems on this copy: 1\n",
           "a bare count against this agent reads as its backlog to clear: #{text}"

    assert text =~ "not qa's to act on",
           "the agent's own row must say plainly that this is not its finding to act on: #{text}"

    assert text =~ "copy-a",
           "the checkout carrying the problem must still be named somewhere: #{text}"

    assert text =~ ~r/1 problem/,
           "the count must still reach the reader, even if not against this agent: #{text}"
  end

  test "a role that can act on problems still sees the full finding, unaffected" do
    work = [agent("coding-id", :coding, working_copy_id: "copy-b", problems: [@finding])]

    text = AgentWorkMapper.text(work)

    assert text =~ "redefining @doc",
           "a role that can fix the problem must still see what it is: #{text}"

    assert text =~ "problems on this copy: 1"
    refute text =~ "not coding's to act on"
  end

  test "a clean copy reads as clean regardless of role" do
    text = AgentWorkMapper.text([agent("qa-clean", :qa, working_copy_id: "copy-c")])

    assert text =~ ~r/no problems|clean/i
    refute text =~ "not qa's to act on"
  end

  test "a copy with a capable role present is not reported as unstaffed, even alongside one that is not" do
    shared = [@finding]

    work = [
      agent("coding-id", :coding, working_copy_id: "copy-d", problems: shared),
      agent("qa-id", :qa, working_copy_id: "copy-d", problems: shared)
    ]

    text = AgentWorkMapper.text(work)

    refute text =~ "nobody present can act on them",
           "a coding agent is on this copy; it must not read as unstaffed: #{text}"

    assert text =~ "redefining @doc",
           "the coding agent's own entry must still show the finding: #{text}"

    assert text =~ "not qa's to act on",
           "the qa agent's own entry must still decline to speak for it: #{text}"
  end

  test "two unstaffed copies are each named once, not merged or dropped" do
    other_finding = %{
      @finding
      | file_path: "lib/my_app/orders.ex",
        line: 3,
        message: "unused alias"
    }

    work = [
      agent("qa-1", :qa,
        working_copy_id: "copy-e",
        working_copy_root: "/tmp/e",
        problems: [@finding]
      ),
      agent("qa-2", :qa, working_copy_id: "copy-f", problems: [@finding, other_finding])
    ]

    text = AgentWorkMapper.text(work)

    assert text =~ "copy-e /tmp/e"
    assert text =~ "copy-f"
    assert text =~ ~r/1 problem/
    assert text =~ ~r/2 problem/
  end
end
