defmodule CodeMySpecSpex.CompactCadenceHelpers do
  @moduledoc "Public surfaces used by the compact cadence scenarios."
  import ExUnit.Assertions
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpecSpex.Fixtures

  def frame(context), do: %Frame{assigns: %{current_scope: context.scope}}

  def fleet(context, count) do
    agents =
      for _ <- 1..count,
          do: Fixtures.running_agent(context.scope, role: "coding", continuous: false)

    Map.put(context, :agents, agents)
  end

  def report(context) do
    {:reply, result, _} = CheckIn.execute(%{}, frame(context))
    refute result.isError, response_text(result)
    Map.put(context, :report, response_text(result))
  end

  # A library tool by name (`ToolLibrary`); an MCP component by module.
  def call(context, name, params) when is_binary(name) do
    frame = frame(context)

    case ToolLibrary.run(
           name,
           params,
           Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
         ) do
      {:ok, text} -> text
      {:error, text} -> flunk("#{name} refused: #{text}")
    end
  end

  def call(context, tool, params) do
    {:reply, result, _} = tool.execute(params, frame(context))
    refute result.isError, response_text(result)
    response_text(result)
  end
end
