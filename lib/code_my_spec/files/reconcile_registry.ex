defmodule CodeMySpec.Files.ReconcileRegistry do
  @moduledoc """
  Which working copies are mid-reconcile, right now.

  A requirement computed while a manifest is landing is computed against a tree
  that has never existed on disk. `FileSync.reconcile/2` is not one transaction —
  `Files.upsert_files/2` chunks at 500, then `delete_removed/2` runs, then
  `ComponentSync` — so a 3937-file manifest is eight upserts, a delete and a
  component sync, and a reader arriving between any two of them sees a partial
  projection.

  What that costs is not the wrong answer, it is that the wrong answer is
  *plausible*. `bdd_specs_exist` going dark reads as "your spec files are gone",
  which is a real thing that happens, so the rational next move is to go and
  find out why. Reported in `7b8a61d2` after exactly that: eight criteria
  checked against their `spec_path` values on disk, `Files.story_by_spec_path/1`
  read to understand the ownership lookup, and a suspected regression in
  spec-file matching — all of it wasted, because the answer was to wait twenty
  seconds.

  So the reader gets to see the state. The reconcile task registers itself here
  and the entry disappears when it exits, which is what makes this safe: there
  is nothing to clean up, no expiry to tune, and a server that restarts mid
  reconcile comes back with an empty table, which is true — nothing is
  reconciling any more.

  Both the channel and the MCP tools run in this server, so this needs no schema
  and no round trip. It is deliberately *not* a fix for the partial read; it
  makes the partial read legible. The fix is to wrap the reconcile in a
  transaction, which is a lock-duration decision on a database three working
  copies and every stop hook share, and wants measuring first.
  """

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Mark this process as the reconcile for `harness_id`.

  Called by the task itself, not by the channel that spawned it, so the
  registration lives exactly as long as the work. `:ok` either way — a marker
  that refused to start would be a reconcile that did not run.
  """
  @spec mark(Ecto.UUID.t() | nil, non_neg_integer()) :: :ok
  def mark(nil, _count), do: :ok

  def mark(harness_id, count) do
    case Registry.register(__MODULE__, to_string(harness_id), %{
           count: count,
           started_at: DateTime.utc_now()
         }) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  @doc """
  What this working copy is mid-reconcile on, or `nil`.

  `%{count: n, started_at: t}` while a manifest of `n` observations is landing.
  """
  @spec in_flight(Ecto.UUID.t() | nil) :: %{count: non_neg_integer(), started_at: DateTime.t()} | nil
  def in_flight(nil), do: nil

  def in_flight(harness_id) do
    case Registry.lookup(__MODULE__, to_string(harness_id)) do
      [{_pid, meta}] -> meta
      [] -> nil
    end
  end
end
