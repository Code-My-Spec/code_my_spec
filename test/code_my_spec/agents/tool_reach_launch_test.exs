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

  test "the launch names the tools the engine carries, so the harness need not read the registry" do
    request = LaunchRequest.for(agent(), ToolRegistry.registry())
    carried = request["direct_tools"]

    assert carried == ToolIndex.carried(ToolRegistry.registry())
    assert "run_script" in carried

    assert Impl.tools(direct_tools: carried)
           |> Enum.map(& &1.name())
           |> Enum.member?("run_script")
  end

  test "the harness implements every tool the server names as carried" do
    assert Enum.sort(CmsHarness.Agents.implemented_tools()) ==
             Enum.sort(ToolIndex.carried(ToolRegistry.registry()))
  end
end
