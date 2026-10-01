defmodule CmsHarness.Agents.ToolResults do
  @moduledoc """
  Every tool result reaches the model as text. Issue `2999a0cb`.

  Alloy puts whatever a tool's `{:error, reason}` carried into the tool-result
  block as it is. `check_answer` answered `{:error, %Anubis.MCP.Error{}}`, the
  provider `Jason.encode!`d the next request, there is no encoder for the
  struct, and the raise took the Alloy server, the turn and the agent with it.

  One middleware rather than a clause per tool: it runs after every tool call
  the engine makes, direct or `run_script`, and a tool added tomorrow is
  covered without knowing this exists. A failed call reads
  `"<tool> failed: <message>"` — the model sees the error and can act on it.
  """

  @behaviour Alloy.Middleware

  alias Alloy.Agent.State

  @max_chars 2_000

  @impl true
  def call(:after_tool_execution, %State{} = state) do
    names = Map.new(state.tool_calls, &{&1[:id], &1[:name]})
    %{state | messages_new: Enum.map(state.messages_new, &as_text(&1, names))}
  end

  def call(_hook, %State{} = state), do: state

  @doc "What a tool's failure says, as a sentence."
  @spec describe(term()) :: String.t()
  def describe(text) when is_binary(text), do: text

  def describe(%Anubis.MCP.Error{message: message, data: data}) do
    case detail(data) do
      nil -> to_string(message)
      detail -> "#{message}: #{detail}"
    end
    |> bound()
  end

  def describe(error) when is_exception(error), do: error |> Exception.message() |> bound()
  def describe(other), do: other |> inspect() |> bound()

  defp detail(%{"message" => message}) when is_binary(message), do: message
  defp detail(%{message: message}) when is_binary(message), do: message
  defp detail(%{original_reason: reason}), do: inspect(reason)
  defp detail(%{"original_reason" => reason}), do: inspect(reason)
  defp detail(_data), do: nil

  defp bound(text), do: String.slice(text, 0, @max_chars)

  defp as_text(%Alloy.Message{content: blocks} = message, names) when is_list(blocks) do
    %{message | content: Enum.map(blocks, &block_as_text(&1, names))}
  end

  defp as_text(message, _names), do: message

  # Text and content-block lists are what a provider already knows how to send.
  defp block_as_text(%{type: type, content: content} = block, _names)
       when type in ["tool_result", "server_tool_result"] and
              (is_binary(content) or is_list(content)),
       do: block

  defp block_as_text(%{type: type, content: content} = block, names)
       when type in ["tool_result", "server_tool_result"] do
    %{block | content: sentence(block, Map.get(names, block[:tool_use_id], "tool"), content)}
  end

  defp block_as_text(block, _names), do: block

  defp sentence(%{is_error: true}, name, content), do: "#{name} failed: #{describe(content)}"
  defp sentence(_block, _name, content), do: describe(content)
end
