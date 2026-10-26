defmodule CodeMySpec.Agents.ALaunchNamesTheAgentsModelTest do
  @moduledoc """
  The harness reads `model` from the launch request, and nothing sent it, so
  every agent ran on its provider's default: a Codex agent on whatever model
  the machine's ~/.codex config named, which RoleProfile's pin never reached.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.{Agent, LaunchRequest, ToolSets}
  alias CodeMySpec.McpServers.ToolRegistry

  defp agent(attrs) do
    struct!(%Agent{id: "a", role: :coding, tools: ToolSets.for_role(:coding)}, attrs)
  end

  defp launch(attrs), do: LaunchRequest.for(agent(attrs), ToolRegistry.registry())

  test "carries the model the agent was given" do
    assert launch(provider: "openai-codex", model: "gpt-6-sol")["model"] == "gpt-6-sol"
  end

  test "carries the role's model for its provider when the agent names none" do
    assert launch(provider: "openai-codex", model: nil)["model"] == "gpt-6-sol"
  end

  test "carries the Claude Code coding default when the agent names none" do
    assert launch(provider: "claude-code", model: nil)["model"] == "claude-sonnet-5"
  end
end
