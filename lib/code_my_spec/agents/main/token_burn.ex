defmodule CodeMySpec.Agents.Main.TokenBurn do
  @moduledoc """
  Each agent's token use over the last hour, for main's check-in, and which of
  them are spending fast enough to be stopped.

  An agent whose conversation grows re-sends all of it every turn, so its cost
  climbs with nothing to show for it: a Codex QA agent used 363M input and
  output tokens over 27 turns in one hour, one turn alone 60M, and nothing
  surfaced it (2026-10-25).

  Read from `agent_turns` without its schema: `AgentPerformance`, which owns
  the table and its `TokenUsage` roll-ups, depends on `Agents`, so it cannot be
  called from here. Its rule holds all the same: a turn the provider reported
  no usage for is unknown, never zero, and an agent with only those reads
  `:unknown`.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @window_s 3_600

  @type t :: %{
          agent_id: Ecto.UUID.t(),
          turns: pos_integer(),
          tokens: non_neg_integer() | :unknown,
          largest_turn: non_neg_integer() | :unknown,
          cache_read: non_neg_integer() | :unknown,
          fresh_threads: non_neg_integer()
        }

  @doc "Every agent on the project that ran a turn in the last hour, the biggest spender first."
  @spec last_hour(Scope.t(), DateTime.t()) :: [t()]
  def last_hour(%Scope{active_project_id: project_id}, now \\ DateTime.utc_now())
      when is_binary(project_id) do
    since = now |> DateTime.add(-@window_s, :second) |> DateTime.to_naive()

    from(t in "agent_turns",
      where: t.project_id == type(^project_id, :binary_id) and t.inserted_at >= ^since,
      group_by: t.agent_id,
      select: %{
        agent_id: type(t.agent_id, :binary_id),
        turns: count(t.id),
        input: sum(t.input_tokens),
        output: sum(t.output_tokens),
        largest_turn:
          max(
            fragment(
              "CASE WHEN ? IS NULL AND ? IS NULL THEN NULL ELSE COALESCE(?, 0) + COALESCE(?, 0) END",
              t.input_tokens,
              t.output_tokens,
              t.input_tokens,
              t.output_tokens
            )
          ),
        cache_read: sum(t.cache_read_tokens),
        # Turns that started a new Codex thread mid-conversation: each sent the
        # whole transcript uncached.
        fresh_threads: count(t.fresh_thread)
      }
    )
    |> Repo.all()
    |> Enum.map(&totals/1)
    |> Enum.sort_by(&rank/1, :desc)
  end

  @doc """
  The agents spending past the threshold: `:hourly` input and output tokens in
  the hour, or any one turn over `:per_turn`. Both configurable under
  `:code_my_spec, :token_burn`.
  """
  @spec over_threshold([t()]) :: [t()]
  def over_threshold(burn), do: Enum.filter(burn, &over?/1)

  defp over?(%{tokens: tokens, largest_turn: largest}),
    do: past?(tokens, limit(:hourly)) or past?(largest, limit(:per_turn))

  defp past?(:unknown, _limit), do: false
  defp past?(count, limit), do: count > limit

  defp limit(key) do
    defaults = [hourly: 50_000_000, per_turn: 10_000_000]
    Keyword.get(Application.get_env(:code_my_spec, :token_burn, []), key, defaults[key])
  end

  defp totals(row) do
    %{
      agent_id: row.agent_id,
      turns: row.turns,
      tokens: in_out(row.input, row.output),
      largest_turn: known(row.largest_turn),
      cache_read: known(row.cache_read),
      fresh_threads: to_int(row.fresh_threads)
    }
  end

  defp in_out(nil, nil), do: :unknown
  defp in_out(input, output), do: to_int(input) + to_int(output)

  defp known(nil), do: :unknown
  defp known(count), do: to_int(count)

  # Postgres sums integers as numeric.
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = count), do: Decimal.to_integer(count)
  defp to_int(count) when is_integer(count), do: count

  defp rank(%{tokens: :unknown}), do: -1
  defp rank(%{tokens: tokens}), do: tokens
end
