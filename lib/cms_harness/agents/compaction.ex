defmodule CmsHarness.Agents.Compaction do
  @moduledoc """
  Report what an agent's compaction decided to keep, so a restart can resume
  from it.

  Alloy compacts on its own when the context fills: it keeps the first message,
  writes a handoff summary of everything before the recent window, and carries
  on. That solves the problem for a *running* agent and not for a restarted one
  — the summary lives in a process, and a process that dies takes it with it.

  So the moment it happens, the resulting message list goes up to the server,
  which writes it as a `conversation_checkpoint`. Coming back is then the
  summary plus what has been said since, rather than a conversation nobody can
  hand a model any more.

  ## Why a middleware and not the telemetry event

  `[:alloy, :compaction, :done]` fires with counts and a turn number, and names
  neither the agent nor what survived — so a handler would know that *an* agent
  compacted and could not say which, or to what. `:after_compaction` is handed
  the state, which is both.

  The reporter arrives through `config.context`, because middleware is a module
  rather than a closure and this one has to reach the agent it is running
  inside. Absent — anything that built an Alloy agent without going through
  `Engine` — it does nothing, which is the right answer for a loop nobody is
  keeping the transcript of.
  """

  @behaviour Alloy.Middleware

  require Logger

  alias Alloy.Agent.State

  @impl true
  def call(:after_compaction, %State{} = state) do
    report(state.config.context[:on_compaction], state)
    state
  end

  def call(_hook, %State{} = state), do: state

  defp report(reporter, state) when is_function(reporter, 1) do
    reporter.(%{
      event: :compacted,
      turn: state.turn,
      messages: Enum.map(State.messages(state), &as_turn/1)
    })
  rescue
    # An agent's work does not stop because the checkpoint could not be sent.
    # The cost of losing one is a longer resume; the cost of a failed turn is
    # the turn.
    error ->
      Logger.warning("[CmsHarness] could not report a compaction: #{Exception.message(error)}")
      :ok
  end

  defp report(_reporter, _state), do: :ok

  # The wire shape, which is the same one a resume arrives in: the summary as
  # text, and the calls and results after it as blocks, so an agent resumed
  # from a checkpoint still holds the working it kept. Thinking is the
  # provider's, signed for one request, and stays where it was produced.
  defp as_turn(%Alloy.Message{role: role, content: text}) when is_binary(text),
    do: %{"role" => to_string(role), "content" => text}

  defp as_turn(%Alloy.Message{role: role, content: blocks}) do
    %{"role" => to_string(role), "content" => Enum.flat_map(blocks, &block/1)}
  end

  defp block(%{type: "text", text: text}), do: [%{"type" => "text", "text" => text}]

  defp block(%{type: "tool_use"} = call),
    do: [
      %{
        "type" => "tool_use",
        "id" => call.id,
        "name" => call.name,
        "input" => call[:input] || %{}
      }
    ]

  defp block(%{type: "tool_result"} = result) do
    [
      %{
        "type" => "tool_result",
        "tool_use_id" => result.tool_use_id,
        "content" => result[:content]
      }
      |> then(&if(result[:is_error], do: Map.put(&1, "is_error", true), else: &1))
    ]
  end

  defp block(_other), do: []
end
