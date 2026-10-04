defmodule CmsHarness.Agents.Engine.UnknownToolMessageTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Impl
  alias CodeMySpec.Agents.{Agent, ToolIndex, ToolSets}
  alias CodeMySpec.McpServers.ToolRegistry

  # A coding agent's real grant, as the launch request sends it.
  defp reach,
    do:
      ToolIndex.reach(
        %Agent{role: :coding, tools: ToolSets.for_role(:coding)},
        ToolRegistry.registry()
      )

  defp direct_names, do: Enum.map(Impl.tools([]), & &1.name())
  defp answer(name), do: Impl.unknown_tool_message(name, reach(), direct_names())

  test "a granted scriptable tool is sent to run_script" do
    assert answer("create_issue") =~ "call it from run_script"
  end

  test "a miscased direct tool names the direct one" do
    message = answer("Tool_Docs")
    assert message =~ "Did you mean `tool_docs`"
    refute message =~ "run_script"
  end

  test "a tool this role lacks says so and names a role that has it" do
    message = answer("submit_qa_result")
    assert message =~ "Your role does not have `submit_qa_result`"
    assert message =~ "do not try run_script"
    assert message =~ "qa"
  end

  test "a name that exists nowhere is told so" do
    message = answer("frobnicate_widgets")
    assert message =~ "No tool named `frobnicate_widgets` exists"
    refute message =~ "call it from run_script"
  end

  test "a launch without tool_reach keeps the run_script hint" do
    assert Impl.unknown_tool_message("create_issue", nil, direct_names()) =~
             "call it from run_script"
  end
end
