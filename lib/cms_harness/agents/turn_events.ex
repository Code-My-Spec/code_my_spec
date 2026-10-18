defmodule CmsHarness.Agents.TurnEvents do
  @moduledoc """
  The two things a watcher of a turn needs that Alloy's events leave out.

  - **A tool call's result, on its `:tool_end`.** Alloy's event carries the
    call and whether it failed, not what it returned, and the conversation
    page shows the result. `:after_tool_call` runs in the turn's process just
    before that call's `:tool_end` is emitted, so the result is kept there and
    `with_result/1` puts it on the envelope as the engine forwards it.
  - **What the model said alongside the calls it asked for.** A turn's final
    text is its result; text written on the way to a tool call otherwise exists
    only as stream deltas, so it is sent as an `:assistant_message` through
    `config.context[:on_turn_event]`.
  """

  @behaviour Alloy.Middleware

  alias Alloy.Agent.State
  alias Alloy.Message

  @impl true
  def call(:after_tool_call, %State{} = state) do
    with %{id: id} <- state.config.context[:current_tool_call],
         %{content: content} <- state.config.context[:current_tool_result] do
      Process.put({__MODULE__, id}, content)
    end

    state
  end

  def call(:after_tool_request, %State{} = state) do
    with report when is_function(report, 1) <- state.config.context[:on_turn_event],
         %Message{role: :assistant} = message <- List.last(state.messages),
         text when is_binary(text) and text != "" <- Message.text(message) do
      report.(%{event: :assistant_message, turn: state.turn, payload: %{text: text}})
    end

    state
  end

  def call(_hook, %State{} = state), do: state

  @doc """
  A `:tool_end` envelope with the call's result added, taken from this process;
  any other envelope unchanged. Called where the turn's events are forwarded,
  which is the process the turn runs in.
  """
  @spec with_result(map()) :: map()
  def with_result(%{event: :tool_end, payload: %{id: id} = payload} = envelope) do
    case Process.delete({__MODULE__, id}) do
      nil -> envelope
      result -> %{envelope | payload: Map.put(payload, :result, result)}
    end
  end

  def with_result(envelope), do: envelope
end
