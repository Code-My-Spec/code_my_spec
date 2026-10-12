defmodule CmsHarness.Agents.SendNow do
  @moduledoc """
  A message sent now reaches a busy agent at its next tool boundary (story
  1051), inside the running turn, with nothing cancelled.

  After each round of tool calls the engine asks the server for any such
  messages. The server consumes them before answering, and they follow the
  round's results as one user message, so the model reads them before it
  decides its next step. A user message of its own rather than text blocks
  beside the results: an OpenAI request carries a tool-result message as
  function outputs only, and would drop the text.

  The asking arrives through `config.context`, because middleware is a module
  and what it asks is per-agent. No asker, or nothing sent, changes nothing.
  """

  @behaviour Alloy.Middleware

  alias Alloy.Agent.State
  alias Alloy.Message

  @impl true
  def call(:after_tool_execution, %State{} = state) do
    case take(state.config.context[:take_send_now]) do
      [] -> state
      texts -> State.append_messages(state, Message.user(Enum.join(texts, "\n\n")))
    end
  end

  def call(_hook, %State{} = state), do: state

  defp take(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, %{"messages" => texts}} when is_list(texts) -> texts
      {:ok, texts} when is_list(texts) -> texts
      _ -> []
    end
  end

  defp take(_none), do: []
end
