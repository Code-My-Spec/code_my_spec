defmodule CmsHarness.Agents.Engine.TheIndexNamesWhatTheEngineCarriesTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Impl
  alias CodeMySpec.Agents.{Agent, ToolIndex, ToolSets}

  @core ~w(read write edit bash)

  # 1a7b1e4c: the index printed `health` and `promote_sync` under "Called
  # directly" and the engine answered `Unknown tool` for both.
  test "\"Called directly\" is exactly what the engine carries" do
    index = ToolIndex.for(%Agent{role: :coding, tools: ToolSets.for_role(:coding)})
    [_, listed] = Regex.run(~r/\*\*Called directly:\*\* ([^\n]+)/, index)

    carried = Impl.tools([]) |> Enum.map(& &1.name()) |> Enum.reject(&(&1 in @core))

    assert Enum.sort(String.split(listed, ", ")) == Enum.sort(carried)
  end

  test "every carried name resolves to a tool of that name" do
    for name <- ToolIndex.carried() do
      module = Impl.direct_tool(name)
      assert Code.ensure_loaded?(module), "no harness tool module for #{name}"
      assert module.name() == name
    end
  end
end
