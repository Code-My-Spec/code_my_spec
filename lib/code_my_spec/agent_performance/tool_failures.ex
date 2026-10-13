defmodule CodeMySpec.AgentPerformance.ToolFailures do
  @moduledoc """
  An agent's tool-call failure rate, and which tools failed most.

  Read from `Conversations.Message.tool_failed` -- the provider's own
  `is_error` on a tool result, surviving a real `record_turn` round trip
  -- rather than a second, separately-counted tally.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Users.Scope

  @large_limit 100_000

  @type report :: %{
          total_calls: non_neg_integer(),
          failed_calls: non_neg_integer(),
          failure_rate: float() | nil,
          by_tool: %{String.t() => non_neg_integer()}
        }

  @doc "One agent's tool-call failure rate, and the count of failures per tool."
  @spec for_agent(Scope.t(), String.t()) :: report()
  def for_agent(%Scope{} = scope, agent_id) do
    with {:ok, agent} <- Agents.fetch_agent(scope, agent_id),
         {:ok, conversation} <-
           Conversations.find_or_create_agent_conversation(
             scope.active_account_id,
             scope.active_project_id,
             agent.id
           ) do
      calls = conversation |> Conversations.list_messages(limit: @large_limit) |> Enum.filter(&tool_result?/1)
      failed = Enum.filter(calls, & &1.tool_failed)

      %{
        total_calls: length(calls),
        failed_calls: length(failed),
        failure_rate: rate(failed, calls),
        by_tool: failed |> Enum.map(&tool_name/1) |> Enum.frequencies()
      }
    else
      _ -> %{total_calls: 0, failed_calls: 0, failure_rate: nil, by_tool: %{}}
    end
  end

  defp tool_result?(%{role: :tool, tool_call_id: id}) when is_binary(id), do: true
  defp tool_result?(_message), do: false

  defp rate(_failed, []), do: nil
  defp rate(failed, calls), do: length(failed) / length(calls)

  defp tool_name(%{sender_id: "agent:" <> name}), do: name
  defp tool_name(_message), do: "unknown"
end
