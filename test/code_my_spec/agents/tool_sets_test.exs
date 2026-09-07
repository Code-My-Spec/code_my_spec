defmodule CodeMySpec.Agents.ToolSetsTest do
  @moduledoc """
  The floor under the tool lists: every name in them names a tool.

  The lists themselves are a judgement and this cannot check one. What it can
  check is that they are made of real things — and when it was written they were
  not: `list_components` and `sync_project` appeared in two of them and name
  nothing.

  An allow-list entry that matches nothing is harmless to the check and
  dangerous to the reader, because thirty names look like thirty tools' worth of
  thought. The expensive version of the same mistake is a tool an agent really
  needs, misspelled or renamed since — the agent is told "this kind of agent is
  not given it", believes it, and stops asking. Nothing failed when that
  happened. Now something does.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.McpServers.CodeMode
  alias CodeMySpec.McpServers.ScriptableTools

  @roles [:qa, :coding, :product]

  setup_all do
    %{real: ScriptableTools.__components__() |> Enum.map(& &1.name()) |> MapSet.new()}
  end

  for role <- @roles do
    test "every tool granted to #{role} exists", %{real: real} do
      # `browser` is a capability, not a tool. The machine publishes its own
      # browser tool names and they are its business, so the grant is "may drive
      # the browser" rather than 85 names that change when the browser server
      # does — see `McpServers.CodeMode.browser_capability/0`. It is excused
      # here by name so a *typo* in a real tool still fails this.
      granted = ToolSets.for_role(unquote(role)) -- [CodeMode.browser_capability()]
      missing = Enum.reject(granted, &MapSet.member?(real, &1))

      assert missing == [],
             "#{unquote(role)} is granted #{inspect(missing)}, which the server does not " <>
               "expose. A name that matches nothing is not a smaller grant, it is a " <>
               "list that reads as bigger than it is — and the same silence hides a " <>
               "tool this type needs that has since been renamed."
    end
  end

  test "main is unscoped rather than a list of everything" do
    refute ToolSets.for_role(:main),
           "main was given a list. Enumerating every tool into a row is a copy of the " <>
             "catalogue that goes stale the day one is added, and the staleness would " <>
             "read as a scoping decision somebody made."
  end

  test "a type nobody defined is granted nothing" do
    assert ToolSets.for_role(:nonexistent) == [],
           "an unknown type fell through to something. The safe answer for a type " <>
             "nobody has thought about is no tools, not all of them."
  end
end
