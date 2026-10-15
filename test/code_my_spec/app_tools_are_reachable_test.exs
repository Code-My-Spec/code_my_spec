defmodule CodeMySpec.AppToolsAreReachableTest do
  @moduledoc """
  Story 1108: the coding agent's own start/restart/stop tools exist over MCP
  and are actually given to the role whose rule names them.

  Same shape as `CreateWorkingCopyIsReachableTest` — nine spex proved
  `execute/2` works and would pass whether or not the tool were registered
  anywhere, which is exactly the gap that shipped a correct, unreachable
  function three times on this project.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.McpServers.ScriptableTools

  @tools ~w(ensure_app_running restart_app stop_app)

  test "the tools exist over MCP" do
    names = ScriptableTools.registrations() |> Enum.map(& &1.name)

    for tool <- @tools do
      assert tool in names,
             "#{tool} is written and tested and no agent can call it, because it " <>
               "is not in the catalogue."
    end
  end

  test "the coding role has all three" do
    for tool <- @tools do
      assert tool in ToolSets.for_role(:coding),
             "#{tool} exists but the role whose rule names it — 'an agent on the " <>
               "copy can start, restart and stop its copy's app' — cannot call it"
    end
  end
end
