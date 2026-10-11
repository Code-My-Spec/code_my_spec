defmodule CmsHarness.Agents.Transcript do
  @moduledoc """
  Every message an agent's loop appends goes up as it is appended, so the
  server holds the conversation the model actually had.

  Before this the server saw a call's name and arguments when it started, a
  result only when it failed, and an assistant's words only at the end of the
  turn — so a restart resumed an agent from a transcript missing everything it
  had done since its last reply, and every restart path grew a special case to
  paper over the gap.

  `:after_tool_request` is the assistant message that asked for the calls, text
  included, before any of them runs. `:after_tool_execution` is their results,
  after `ToolResults` has made each one text — the order in `Engine` puts this
  last. A turn's final words still travel as its `:message` event.
  """

  @behaviour Alloy.Middleware

  require Logger

  alias Alloy.Agent.State

  @impl true
  def call(hook, %State{messages_new: [latest | _]} = state)
      when hook in [:after_tool_request, :after_tool_execution] do
    report(state.config.context[:on_transcript], latest, names(state))
    state
  end

  def call(_hook, %State{} = state), do: state

  @doc """
  An Alloy message as it crosses the wire: string keys, content blocks kept.

  A plain-text message stays a string, the shape every resume already carried.
  `names` puts the tool's name on each result block, which the block itself
  does not carry and the transcript renders by.
  """
  @spec encode(Alloy.Message.t(), map()) :: map()
  def encode(message, names \\ %{})

  def encode(%Alloy.Message{role: role, content: content}, _names) when is_binary(content),
    do: %{"role" => to_string(role), "content" => content}

  def encode(%Alloy.Message{role: role, content: blocks}, names) when is_list(blocks) do
    %{"role" => to_string(role), "content" => Enum.flat_map(blocks, &block(&1, names))}
  end

  defp report(reporter, message, names) when is_function(reporter, 1) do
    reporter.(%{event: :transcript, message: encode(message, names)})
  rescue
    # The turn goes on. A message that did not reach the server costs a
    # shorter resume, not the work in progress.
    error ->
      Logger.warning("[CmsHarness] could not report a message: #{Exception.message(error)}")
      :ok
  end

  defp report(_reporter, _message, _names), do: :ok

  defp names(state), do: Map.new(state.tool_calls, &{&1[:id], &1[:name]})

  # Thinking is the provider's, signed for one request, and not part of what
  # was said; it is left where it was produced.
  defp block(%{type: "thinking"}, _names), do: []
  defp block(%{type: "redacted_thinking"}, _names), do: []

  defp block(%{type: "text", text: text}, _names), do: [%{"type" => "text", "text" => text}]

  defp block(%{type: type} = call, _names) when type in ["tool_use", "server_tool_use"],
    do: [
      %{
        "type" => "tool_use",
        "id" => call[:id],
        "name" => call[:name],
        "input" => call[:input] || %{}
      }
    ]

  defp block(%{type: type, tool_use_id: id} = result, names)
       when type in ["tool_result", "server_tool_result"] do
    [
      %{
        "type" => "tool_result",
        "tool_use_id" => id,
        "name" => Map.get(names, id),
        "content" => result_text(result[:content]),
        "is_error" => result[:is_error] == true
      }
    ]
  end

  defp block(_other, _names), do: []

  defp result_text(text) when is_binary(text), do: text

  defp result_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{type: "text", text: text} -> text
      %{"type" => "text", "text" => text} -> text
      %{type: "image"} -> "← image"
      %{"type" => "image"} -> "← image"
      other -> inspect(other)
    end)
  end

  defp result_text(nil), do: ""
  defp result_text(other), do: inspect(other)
end
