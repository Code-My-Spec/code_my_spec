defmodule CodeMySpec.CreateWorkingCopyIsReachableTest do
  @moduledoc """
  The tool an agent is supposed to call is one an agent can actually call.

  Nine spex drive `CreateWorkingCopy.execute/2` directly and would pass whether
  or not the tool were registered anywhere — which is the exact shape that has
  shipped inert on this project three times: `internal_agent?` reading the wrong
  opts, the missing `RoleBrief` alias, `put_refreshed_at` guarding a struct type
  that never matched. Each was correct code nothing could reach, and each was
  caught only by looking at the artifact rather than at the function.

  Two registrations stand between the function and an agent, and neither is
  exercised by calling `execute/2`:

  - `ScriptableTools` decides what exists over MCP at all.
  - `ToolSets` decides which roles are given it.

  So this asserts the wiring, not the behaviour. It is deliberately dull.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.McpServers.ScriptableTools

  test "the tool exists over MCP" do
    # By the name an agent types, not by the module. The module being present
    # would not prove the tool is callable under the name everything else refers
    # to it by — `ToolSets`, the prompts and the docs all say
    # `create_working_copy`.
    names = ScriptableTools.__components__() |> Enum.map(& &1.name)

    assert "create_working_copy" in names,
           "the tool is written and tested and no agent can call it, because it " <>
             "is not in the catalogue. Calling execute/2 from a spex proves the " <>
             "function works and says nothing about whether anything can reach it."
  end

  test "discarding one is reachable too" do
    names = ScriptableTools.__components__() |> Enum.map(& &1.name)

    assert "offboard_working_copy" in names,
           "an agent can make a working copy and never let go of one. A boundary " <>
             "is only usable if both ends are reachable by whoever is doing the work."
  end

  test "the product agent is given both" do
    assert "offboard_working_copy" in ToolSets.for_role(:product)

    assert "create_working_copy" in ToolSets.for_role(:product),
           "placement and creation belong to the role that shapes the work — " <>
             "`list_working_copies` and `assign_epic_to_working_copy` are already " <>
             "product's, and creating the copy they place work on is the same job."
  end

  test "the main agent is unrestricted, so it has it too" do
    assert ToolSets.for_role(:main) == nil,
           "main is scoped to a list now, so `create_working_copy` has to be on " <>
             "it explicitly — an agent that can shape an epic and not make " <>
             "somewhere to build it stops halfway through its own journey."
  end

  test "the roles that should not create checkouts do not have it" do
    for role <- [:coding, :qa] do
      refute "create_working_copy" in ToolSets.for_role(role),
             "#{role} can mint checkouts. That role works *in* a copy; making " <>
               "more of them is not its job, and a coding agent that can create " <>
               "worktrees can fill a disk without anybody asking it to."

      refute "offboard_working_copy" in ToolSets.for_role(role),
             "#{role} can discard checkouts. Discarding one ends the agents on " <>
               "it, so a coding agent could stop its own siblings."
    end
  end
end
