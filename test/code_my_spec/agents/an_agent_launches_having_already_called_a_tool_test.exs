defmodule CodeMySpec.Agents.AnAgentLaunchesHavingAlreadyCalledAToolTest do
  @moduledoc """
  The wire format is taught by demonstration, not description.

  `claude-code` emulates tool calling — the definitions arrive as
  `available_tools` and a call is a `tool_calls` entry in a JSON object, not a
  native tool use. Agents got that wrong about one turn in ten, returning no
  call and a fabricated account of one failing, and four rewrites of the prose
  that explained it moved the rate around inside noise. Two of them made it
  worse: prose cannot describe the format without naming what a failure looks
  like, and agents quoted that naming back as though it were a live result.

  So the transcript opens with the agent having already made one call of each
  shape. Measured on the two criteria that fabricated most: 3535 went from 7 in
  10 at its best under prose to 10 in 10 with no prose at all.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.{Agent, LaunchRequest}
  alias CodeMySpec.McpServers.{LocalServer, ScriptableTools, ToolRegistry}

  defp request,
    do:
      LaunchRequest.for(
        %Agent{id: "a", provider: "claude-code", role: :coding},
        ToolRegistry.registry()
      )

  test "it opens with a direct call and a nested one, both answered" do
    [direct, direct_result, nested, nested_result | _] = request()["messages"]

    assert %{"role" => "assistant", "content" => [%{"type" => "tool_use", "name" => "health"}]} =
             direct

    assert %{"role" => "user", "content" => [%{"type" => "tool_result", "content" => "ok"}]} =
             direct_result

    assert %{"role" => "assistant", "content" => [%{"name" => "run_script", "input" => input}]} =
             nested

    assert input["script"] =~ "script_health(",
           "the nested turn has to reach a Lua function through `run_script` — " <>
             "that is the shape agents get wrong, and the one worth demonstrating"

    assert %{"role" => "user", "content" => [%{"type" => "tool_result", "content" => "ok"}]} =
             nested_result
  end

  test "the demonstration comes before anything the agent is asked to do" do
    said = %{"role" => "user", "content" => "what the operator wants"}

    messages =
      LaunchRequest.for(
        %Agent{id: "a", provider: "claude-code", history: [said]},
        ToolRegistry.registry()
      )["messages"]

    assert List.last(messages) == said,
           "a demonstration after the request is a distraction; before it, it is the format"
  end

  test "both tools it demonstrates are ones the agent can actually reach" do
    # A seeded call naming a tool absent from `available_tools` would teach the
    # exact confusion this exists to remove.
    assert Enum.any?(LocalServer.__components__(), &(&1.name == "health"))
    assert Enum.any?(ScriptableTools.registrations(), &(&1.name == "script_health"))
  end
end
