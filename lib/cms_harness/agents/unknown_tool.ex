defmodule CmsHarness.Agents.UnknownTool do
  @moduledoc """
  A call to a tool the agent does not carry is told where that tool is
  reachable, not just "Unknown tool".

  The wording is per agent (`Engine.Impl.unknown_tool_message/3`, from the
  launch request's tool reach), so it rides the context as `:unknown_tool`.
  """

  @behaviour Alloy.Middleware

  alias Alloy.Agent.State

  @impl true
  def call(:after_tool_call, %State{} = state) do
    context = state.config.context

    with word when is_function(word, 1) <- context[:unknown_tool],
         %{name: name} <- context[:current_tool_call],
         %{is_error: true, content: "Unknown tool: " <> ^name} = result <-
           context[:current_tool_result] do
      {:result, %{result | content: word.(name)}}
    else
      _ -> state
    end
  end

  def call(_hook, %State{} = state), do: state
end
