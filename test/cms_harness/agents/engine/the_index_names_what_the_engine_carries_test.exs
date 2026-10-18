defmodule CmsHarness.Agents.Engine.TheIndexNamesWhatTheEngineCarriesTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Impl
  alias CodeMySpec.Agents.{Agent, ToolIndex, ToolSets}
  alias CodeMySpec.McpServers.ToolRegistry

  @core ~w(read write edit bash)

  # 1a7b1e4c: the index printed `health` and `promote_sync` under "Called
  # directly" and the engine answered `Unknown tool` for both.
  test "\"Called directly\" is exactly what the engine carries" do
    index =
      ToolIndex.for(
        %Agent{role: :coding, tools: ToolSets.for_role(:coding)},
        ToolRegistry.registry()
      )

    [_, listed] = Regex.run(~r/\*\*Called directly:\*\* ([^\n]+)/, index)

    carried =
      Impl.tools(direct_tools: ToolIndex.carried_definitions(ToolRegistry.registry()))
      |> Enum.map(&Impl.tool_name/1)
      |> Enum.reject(&(&1 in @core))

    assert Enum.sort(String.split(listed, ", ")) == Enum.sort(carried)
  end

  test "every carried definition builds a tool of that name" do
    for %{"name" => name} = definition <- ToolIndex.carried_definitions(ToolRegistry.registry()) do
      assert definition |> Impl.direct_tool() |> Impl.tool_name() == name
    end
  end
end
