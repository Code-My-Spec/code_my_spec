defmodule CodeMySpec.AgentPerformance.TokenUsage do
  @moduledoc """
  Token usage recorded per agent turn, rolled up per agent, per story and
  per provider.

  Story 1092 criteria 1976-1979. A turn with no usage in the provider's
  response is recorded with every token field nil, and a roll-up with
  nothing but nil fields reads back `:unknown` rather than `0` -- those
  mean different things here (criterion 1978) and nothing coerces one into
  the other.
  """

  import Ecto.Query

  alias CodeMySpec.AgentPerformance.AgentTurn
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type agent_totals :: %{
          input_tokens: non_neg_integer() | :unknown,
          output_tokens: non_neg_integer() | :unknown,
          cache_read_tokens: non_neg_integer() | :unknown,
          cache_write_tokens: non_neg_integer() | :unknown,
          provider: String.t() | nil,
          model: String.t() | nil
        }

  @type story_totals :: %{
          total: non_neg_integer() | :unknown,
          by_provider: %{String.t() => non_neg_integer()}
        }

  @doc """
  Record one finished turn's token usage against the agent that ran it.

  Takes the running agent's own id, story id and provider rather than the
  struct itself -- nothing here needs the rest of it, and `Agents.Agent` is
  not this context's to reach into. `story_id` is read by the caller at
  this moment and kept on the row from then on: a turn belongs to whatever
  story was active when it happened, not to wherever the agent ends up
  later.
  """
  @spec record(Scope.t(), String.t(), integer() | nil, String.t() | nil, map()) :: :ok
  def record(%Scope{} = scope, agent_id, story_id, provider, response)
      when is_binary(agent_id) and is_map(response) do
    usage = response["usage"] || %{}

    %AgentTurn{}
    |> AgentTurn.changeset(%{
      account_id: scope.active_account_id,
      project_id: scope.active_project_id,
      agent_id: agent_id,
      story_id: story_id,
      provider: provider,
      model: response["model"],
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      cache_read_tokens: usage["cache_read_input_tokens"],
      cache_write_tokens: usage["cache_creation_input_tokens"],
      fresh_thread: usage["fresh_thread"]
    })
    |> Repo.insert()

    :ok
  end

  @doc "One agent's token totals across every turn it has run."
  @spec for_agent(Scope.t(), String.t()) :: agent_totals()
  def for_agent(%Scope{} = scope, agent_id) do
    turns =
      AgentTurn
      |> where([t], t.agent_id == ^agent_id and t.account_id == ^scope.active_account_id)
      |> order_by([t], desc: t.inserted_at)
      |> Repo.all()

    %{
      input_tokens: sum_or_unknown(turns, :input_tokens),
      output_tokens: sum_or_unknown(turns, :output_tokens),
      cache_read_tokens: sum_or_unknown(turns, :cache_read_tokens),
      cache_write_tokens: sum_or_unknown(turns, :cache_write_tokens),
      provider: latest(turns, :provider),
      model: latest(turns, :model)
    }
  end

  @doc "A story's total tokens (input + output), and the same broken down by provider."
  @spec for_story(Scope.t(), integer()) :: story_totals()
  def for_story(%Scope{} = scope, story_id) when is_integer(story_id) do
    turns =
      AgentTurn
      |> where([t], t.story_id == ^story_id and t.account_id == ^scope.active_account_id)
      |> Repo.all()

    with_usage = Enum.filter(turns, &(&1.input_tokens || &1.output_tokens))

    %{
      total: total_in_out(with_usage),
      by_provider:
        with_usage
        |> Enum.group_by(& &1.provider)
        |> Enum.reject(fn {provider, _rows} -> is_nil(provider) end)
        |> Map.new(fn {provider, rows} -> {provider, total_in_out(rows)} end)
    }
  end

  defp total_in_out([]), do: :unknown

  defp total_in_out(turns) do
    Enum.reduce(turns, 0, fn t, acc -> acc + (t.input_tokens || 0) + (t.output_tokens || 0) end)
  end

  defp sum_or_unknown(turns, field) do
    case Enum.reject(turns, &is_nil(Map.get(&1, field))) do
      [] -> :unknown
      present -> present |> Enum.map(&Map.get(&1, field)) |> Enum.sum()
    end
  end

  defp latest([], _field), do: nil
  defp latest([turn | _], field), do: Map.get(turn, field)
end
