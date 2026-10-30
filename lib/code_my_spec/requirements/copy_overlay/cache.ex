defmodule CodeMySpec.Requirements.CopyOverlay.Cache do
  @moduledoc """
  File verdicts the server computed for a copy with no current report, one
  entry per copy, kept while its key (the records' fingerprint and the copy's
  files) holds. Owns the table and nothing else, like `DrainCost`.

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

  @doc "The copy's entry when `key` still matches it, else `compute.()`, kept under `key`."
  @spec fetch(Ecto.UUID.t(), term(), (-> term())) :: term()
  def fetch(copy, key, compute) do
    case :ets.whereis(@table) do
      :undefined ->
        compute.()

      _table ->
        case :ets.lookup(@table, copy) do
          [{^copy, ^key, value}] ->
            value

          _missing_or_moved ->
            value = compute.()
            :ets.insert(@table, {copy, key, value})
            value
        end
    end
  end
end
