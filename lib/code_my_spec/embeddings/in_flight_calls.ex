defmodule CodeMySpec.Embeddings.InFlightCalls do
  @moduledoc """
  How many `FLAME.call/3`s are in flight on a pool, right now — the fact
  `BurstBox.busy?/3`'s embedding half needs, with no FLAME-internals
  introspection to get it (story 877, item 1 correction).

  `FLAME.Pool`'s own process state already knows which runner is mid-call,
  but there is no public API to read it, and reading it anyway
  (`:sys.get_state/1` against `CodeMySpec.EmbedPool`) would be a real
  coupling to a dependency's internal, undocumented shape — one a FLAME
  version bump could break with no compile-time warning. So this owns the
  fact itself instead: every call this app makes through `EmbedPool` is
  expected to go through `call/3` here rather than `FLAME.call/3` directly,
  which counts a call in flight before dispatching and counts it back out
  after — success, failure, or exit alike, the same "every path cleans up"
  discipline the rest of this codebase already applies to a box or a
  builder.

  ETS, owned by this process, keyed by pool name — not by which runner node
  actually executed the call. `BurstBox`'s own moduledoc: every environment
  has exactly one shared burst box, so one pool maps to exactly one box
  today, and "anything in flight on this pool" already answers "is the box
  busy" without needing to also match a runner's node. A per-node key would
  only start mattering if an environment ever hosted more than one
  embedding box at once, which it does not.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Run `fun` as `FLAME.call(pool, fun, opts)`, with `pool`'s in-flight count
  incremented first and decremented after — whether `fun` returns, raises,
  or the call itself exits (a runner crash, a FLAME timeout).

  Every existing `FLAME.call(CodeMySpec.EmbedPool, ...)` call site should
  call this instead, unchanged otherwise: same pool, same function, same
  opts, same return.
  """
  @spec call(FLAME.Pool.name(), (-> result), keyword()) :: result when result: term()
  def call(pool, fun, opts \\ []) when is_function(fun, 0) do
    increment(pool)

    try do
      FLAME.call(pool, fun, opts)
    after
      decrement(pool)
    end
  end

  @doc "Whether any call tracked through `call/3` is currently in flight on `pool`."
  @spec any_in_flight?(FLAME.Pool.name()) :: boolean()
  def any_in_flight?(pool) do
    case :ets.whereis(@table) do
      :undefined -> false
      _ -> count(pool) > 0
    end
  end

  @doc false
  @spec count(FLAME.Pool.name()) :: non_neg_integer()
  def count(pool) do
    case :ets.lookup(@table, pool) do
      [{^pool, count}] -> count
      [] -> 0
    end
  end

  defp increment(pool), do: :ets.update_counter(@table, pool, {2, 1}, {pool, 0})

  # Never below zero: a decrement racing a table that was just reset (or a
  # bug that double-decrements) must not leave a negative count reading as
  # "in flight" is somehow less than none — `any_in_flight?/1` only ever
  # asks ">0", but a negative count is still a wrong number to have on
  # record.
  defp decrement(pool) do
    case :ets.update_counter(@table, pool, {2, -1}, {pool, 0}) do
      n when n < 0 -> :ets.update_element(@table, pool, {2, 0})
      n -> n
    end
  end
end
