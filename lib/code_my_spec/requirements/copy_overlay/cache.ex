defmodule CodeMySpec.Requirements.CopyOverlay.Cache do
  @moduledoc """
  What the server derives from a copy's File rows (its computed file verdicts,
  the digest of its files), one entry per name, kept while its key (the
  records' fingerprint, the copy's files) holds. Owns the table and nothing
  else, like `DrainCost`.

  Where the table is not running (the harness, a desktop build without it),
  every fetch computes: slower, never wrong.
  """

  use GenServer

  @table :requirements_copy_overlay_cache

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "The entry named `name` when `key` still matches it, else `compute.()`, kept under `key`."
  @spec fetch(term(), term(), (-> term())) :: term()
  def fetch(name, key, compute) do
    case :ets.whereis(@table) do
      :undefined ->
        compute.()

      _table ->
        case :ets.lookup(@table, name) do
          [{^name, ^key, value}] ->
            value

          _missing_or_moved ->
            value = compute.()
            :ets.insert(@table, {name, key, value})
            value
        end
    end
  end
end
