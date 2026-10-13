defmodule CodeMySpec.CodeMode.ARefusalDoesNotTellAnAgentToCallWhatItLacksTest do
  @moduledoc """
  The exclusion refusal stops advising a call the caller cannot make.

  Issue `bd699695`, found by a QA agent on story 1008. `run_script` refused
  `list_user_questions` with:

      ... it belongs with the asking tools, which a script cannot call. Call it
      directly as a tool.

  and then:

      If calling `list_user_questions` directly answers `Unknown tool`, you do
      not have it — your MCP connection negotiated its tool list when it opened
      ... Reconnect (`/mcp`) and call it again.

  Both halves are wrong for that caller. `list_user_questions` is not in the QA
  role's set on purpose, so "call it directly" is unfollowable and "reconnect"
  names the one explanation that does not apply — an in-VM agent has no `/mcp`
  to give. The agent said so exactly: "I have no /mcp reconnect capability from
  here either."

  The fix is the one the issue gives: the refusal knows the tool and the frame
  knows the caller, so one lookup against the same grant the carrying decision
  uses separates "not from a script, call it directly" from "your role does not
  carry this". The reconnect paragraph belongs only in the first case.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Catalog

  defp catalog do
    Catalog.from(
      [%{name: "list_stories", description: "List stories"}],
      fn _tool -> fn _args -> {:ok, "ok"} end end,
      nil
    )
  end

  # A caller whose role does not carry `list_user_questions` — the QA case. Its
  # grant is passed the way `run_script` passes it.
  defp run_without_the_tool(script) do
    CodeMode.eval(catalog(), script,
      out_of_scope: [],
      agent_kind: :qa,
      carried: Catalog.excluded() -- ["list_user_questions"]
    )
  end

  # A caller that carries it — the main agent, or a person.
  defp run_with_the_tool(script) do
    CodeMode.eval(catalog(), script, out_of_scope: [], agent_kind: nil, carried: :all)
  end

  test "a caller that does not carry it is told so" do
    result = run_without_the_tool(~s|return list_user_questions({})|)

    assert result.error.message =~ "cannot be called from a script"
    assert result.error.message =~ ~r/role|carry/i,
           "the refusal must name that the role withholds it, not leave the agent " <>
             "hunting for a tool the role deliberately does not grant"
  end

  test "and is not told to reconnect for a tool its role withholds" do
    result = run_without_the_tool(~s|return list_user_questions({})|)

    refute result.error.message =~ "/mcp",
           "reconnect names the one explanation that is wrong here, and an in-VM " <>
             "agent cannot perform it"
  end

  test "and is not told to call it directly" do
    result = run_without_the_tool(~s|return list_user_questions({})|)

    refute result.error.message =~ "Call it directly as a tool",
           "calling it directly is exactly what this caller cannot do"
  end

  test "a caller that carries it still gets the direct-call advice" do
    result = run_with_the_tool(~s|return list_user_questions({})|)

    assert result.error.message =~ "Call it directly as a tool"
    assert result.error.message =~ "/mcp"
  end
end
