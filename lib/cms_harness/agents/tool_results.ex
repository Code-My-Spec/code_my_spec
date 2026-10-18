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
  def call(:after_tool_call, %State{} = state) do
    case state.config.context[:current_tool_result] do
      %{content: content} = result when not is_binary(content) and not is_list(content) ->
        name = state.config.context[:current_tool_call][:name] || "tool"
        {:result, %{result | content: sentence(result.is_error, name, content)}}

      _text_or_blocks ->
        state
    end
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

  defp sentence(true, name, content), do: "#{name} failed: #{describe(content)}"
  defp sentence(_is_error, _name, content), do: describe(content)
end
