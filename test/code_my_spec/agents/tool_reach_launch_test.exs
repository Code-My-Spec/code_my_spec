defmodule CodeMySpec.Agents.ToolReachLaunchTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Impl
  alias CodeMySpec.Agents.{Agent, LaunchRequest, ToolIndex, ToolSets}
  alias CodeMySpec.McpServers.ToolRegistry

  defp agent,
    do: %Agent{id: "a", provider: "claude-code", role: :coding, tools: ToolSets.for_role(:coding)}

  test "the launch carries tool_reach, and the index text renders the same grant" do
    request = LaunchRequest.for(agent(), ToolRegistry.registry())
    reach = request["tool_reach"]

    assert reach == ToolIndex.reach(agent(), ToolRegistry.registry())
    assert "create_issue" in reach["scriptable"]
    assert "submit_qa_result" in reach["not_granted"]
    assert "qa" in reach["holders"]["submit_qa_result"]

    assert request["tool_index"] =~
             "**Called from inside `run_script`:** " <> Enum.join(reach["scriptable"], ", ")
  end

  test "the launch carries the tools the engine carries, so the harness need not read the registry" do
    request = LaunchRequest.for(agent(), ToolRegistry.registry())
    carried = request["direct_tools"]

    assert Enum.map(carried, & &1["name"]) ==
             ToolIndex.carried(ToolRegistry.registry(), agent().role)

    assert Enum.all?(carried, &(is_binary(&1["description"]) and is_map(&1["input_schema"])))
  end

  # Main has no copy of its own, so its read/write/edit/bash
  # are the server's, naming a copy; any other agent keeps its own copy's four.
  test "only Main carries the server's read, write, edit and bash, which replace its local four" do
    main = %{agent() | role: :main}
    main_tools = LaunchRequest.for(main, ToolRegistry.registry())["direct_tools"]
    names = ~w(read write edit bash)

    assert Enum.all?(names, fn n -> Enum.any?(main_tools, &(&1["name"] == n)) end)
    refute Enum.any?(request_tools(), &(&1["name"] in names))

    built = Impl.tools(direct_tools: main_tools)

    for name <- names do
      [tool] = Enum.filter(built, &(Impl.tool_name(&1) == name))
      refute is_atom(tool), "Main's #{name} must forward to the server, not run locally"
    end

    assert CmsHarness.Agents.Tools.Read in Impl.tools(direct_tools: request_tools())
  end

  test "the harness builds every tool the server names as carried" do
    built = Impl.tools(direct_tools: request_tools()) |> Enum.map(&Impl.tool_name/1)

    for name <- ToolIndex.carried(ToolRegistry.registry()), do: assert(name in built)
  end

  # A definition the harness has a module for keeps the module; the rest
  # forward, and describe themselves as the server does.
  test "a forwarded tool is the server's description and schema" do
    [definition] = Enum.filter(request_tools(), &(&1["name"] == "start_task"))
    tool = Impl.direct_tool(definition)

    assert tool.description == definition["description"]
    assert tool.input_schema == definition["input_schema"]

    assert Impl.direct_tool(Enum.find(request_tools(), &(&1["name"] == "run_script"))) ==
             CmsHarness.Agents.Tools.RunScript
  end

  defp request_tools, do: LaunchRequest.for(agent(), ToolRegistry.registry())["direct_tools"]
end
