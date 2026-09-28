defmodule CodeMySpec.Agents.ToolReachLaunchTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.{Agent, LaunchRequest, ToolIndex, ToolSets}

  defp agent,
    do: %Agent{id: "a", provider: "claude-code", role: :coding, tools: ToolSets.for_role(:coding)}

  test "the launch carries tool_reach, and the index text renders the same grant" do
    request = LaunchRequest.for(agent())
    reach = request["tool_reach"]

    assert reach == ToolIndex.reach(agent())
    assert "create_issue" in reach["scriptable"]
    assert "submit_qa_result" in reach["not_granted"]
    assert "qa" in reach["holders"]["submit_qa_result"]

    assert request["tool_index"] =~
             "**Called from inside `run_script`:** " <> Enum.join(reach["scriptable"], ", ")
  end
end
