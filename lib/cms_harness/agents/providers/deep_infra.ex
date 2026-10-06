defmodule CmsHarness.Agents.Providers.DeepInfra do
  @moduledoc """
  DeepInfra through Alloy's OpenAI-compatible provider, with tool-call ids filled in.

  DeepInfra can answer a tool call with no `id`. Alloy keeps the nil, and the next
  request echoes it back as `tool_calls[].id` and `tool_call_id`, which DeepInfra
  then rejects ("Input should be a valid string"). So every turn after the first
  tool call failed.

  Ids are filled on the way out (history, including turns already stored with a
  nil) and on the way back (the response), pairing each tool result with the call
  before it in order.
  """

  @behaviour Alloy.Provider

  alias Alloy.Message
  alias Alloy.Provider.OpenAICompat

  @impl true
  def complete(messages, tool_defs, config) do
    messages |> with_ids() |> OpenAICompat.complete(tool_defs, config) |> response_with_ids()
  end

  @impl true
  def stream(messages, tool_defs, config, on_chunk) do
    messages
    |> with_ids()
    |> OpenAICompat.stream(tool_defs, config, on_chunk)
    |> response_with_ids()
  end

  defp response_with_ids({:ok, %{messages: messages} = response}),
    do: {:ok, %{response | messages: with_ids(messages)}}

  defp response_with_ids(other), do: other

  # Walks the history once. A tool_use with no id gets one from its position; the
  # tool_result blocks that follow take the pending ids in order.
  defp with_ids(messages) do
    {messages, _pending} =
      messages
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {message, index}, pending -> fill(message, index, pending) end)

    messages
  end

  defp fill(%Message{role: :assistant, content: blocks} = message, index, _pending)
       when is_list(blocks) do
    {blocks, ids} =
      blocks
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {%{type: "tool_use"} = block, position}, ids ->
          id = block_id(block) || "call_#{index}_#{position}"
          {Map.put(block, :id, id), ids ++ [id]}

        {block, _position}, ids ->
          {block, ids}
      end)

    {%{message | content: blocks}, ids}
  end

  defp fill(%Message{role: :user, content: blocks} = message, _index, pending)
       when is_list(blocks) do
    {blocks, rest} =
      Enum.map_reduce(blocks, pending, fn
        %{type: "tool_result"} = block, [id | rest] ->
          {Map.update(block, :tool_use_id, id, &(&1 || id)), rest}

        block, rest ->
          {block, rest}
      end)

    {%{message | content: blocks}, rest}
  end

  defp fill(message, _index, pending), do: {message, pending}

  defp block_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp block_id(_block), do: nil
end
