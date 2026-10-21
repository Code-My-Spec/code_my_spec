defmodule CodeMySpec.Repo do
  use Boundary, top_level?: true, deps: [], exports: :all

  @adapter Application.compile_env(:code_my_spec, :adapter, Ecto.Adapters.Postgres)

  use Ecto.Repo,
    otp_app: :code_my_spec,
    adapter: @adapter

  @doc "Whether this build's Repo runs on SQLite (the desktop) rather than Postgres."
  def sqlite?, do: @adapter == Ecto.Adapters.SQLite3

  # SQLite has no row locks. Its transactions begin IMMEDIATE (the write lock up
  # front), so a read-modify-write is already serialized and `FOR UPDATE` adds
  # nothing.
  @impl true
  def prepare_query(_operation, %{lock: lock} = query, opts) when not is_nil(lock) do
    if sqlite?(), do: {%{query | lock: nil}, opts}, else: {query, opts}
  end

  def prepare_query(_operation, query, opts), do: {query, opts}

  @doc """
  Hold `key` until the surrounding transaction ends: one row per key in
  `locks`, locked `FOR UPDATE`. On SQLite the transaction's write lock already
  serializes, so the row only has to exist.
  """
  @spec lock!(String.t()) :: :ok
  def lock!(key) when is_binary(key) do
    import Ecto.Query, only: [from: 2]

    insert_all("locks", [%{key: key}], on_conflict: :nothing)
    one!(from(l in "locks", where: l.key == ^key, select: l.key, lock: "FOR UPDATE"))
    :ok
  end
end
