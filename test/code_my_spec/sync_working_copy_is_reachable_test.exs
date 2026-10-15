defmodule CodeMySpec.SyncWorkingCopyIsReachableTest do
  @moduledoc """
  The same wiring check `CreateWorkingCopyIsReachableTest` makes for its own
  tool: `execute/2` being correct says nothing about whether an agent can
  ever call it. 8f5ebfb2.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.McpServers.ScriptableTools

  test "the tool exists over MCP" do
    names = ScriptableTools.__components__() |> Enum.map(& &1.name)

    assert "sync_working_copy" in names,
           "the tool is written and tested and no agent can call it, because it " <>
             "is not in the catalogue."
  end

  test "the main agent is unrestricted, so it has it too" do
    assert ToolSets.for_role(:main) == nil
  end

  test "the roles that work inside a copy do not get to point another copy's harness at main" do
    for role <- [:coding, :qa, :product] do
      refute "sync_working_copy" in (ToolSets.for_role(role) || []),
             "#{role} can sync an arbitrary working copy's checkout -- the same working-" <>
               "copy-management category create_working_copy and offboard_working_copy " <>
               "are reserved out of"
    end
  end
end
