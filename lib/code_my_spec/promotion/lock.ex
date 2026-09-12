defmodule CodeMySpec.Promotion.Lock do
  @moduledoc """
  Which project has a promotion in flight, right now — and the guard that
  keeps a second one from starting alongside it.

  Measured, 2026-09-11: `:4000` booted serving one agent's merge, then three
  minutes later booted serving a second agent's — a commit that was not a
  descendant of the first and not on `main`. Nothing told either agent. A QA
  agent was mid-run against the first build when the second promotion swapped
  it out from underneath, so every criterion it checked afterward was measured
  against code that was no longer there (db97272b). A promotion is
  gate -> merge -> restart, none of it atomic, so two in flight can merge in
  either order and restart in either order — the surviving build is decided
  by timing, and QA has no way to know which one it got.

  Refuses rather than queues, on purpose: this codebase already reaches for
  that shape for the same class of problem — `working_copy_in_use` refuses a
  second harness on one checkout rather than waiting its turn — and a queued
  promotion whose branch has since moved on is a merge nobody asked for. The
  refusal names when the holder started, which is what lets an agent tell "a
  promotion is genuinely running" from "one is stuck."

  ## Why a Registry, not a database row

  A row would need something to clear it when the holder crashes — a
  supervisor exit that never reaches its `after` block leaves a permanent
  lock nothing can take back. `Registry.register/3` ties the entry to the
  registering process by monitor: it is gone the instant that process is,
  crash or not, and a server restart comes back with an empty table, which is
  true — nothing is promoting any more. Same reasoning as
  `CodeMySpec.Provisioning.RunLock`, which guards a different in-flight run
  the same way; a separate module rather than a shared one because the two
  are different work with different holders, and sharing one Registry would
  mean a devops setup run and a promotion for the same project contending for
  a lock neither of them is holding.

  ## The lock is the atomicity, not a check before one

  `Registry.register/3` for `keys: :unique` is a single atomic decision: of
  two processes racing to register the same key, exactly one gets `{:ok, _}`
  and the other gets `{:error, {:already_registered, _}}`, with no window
  between "checked" and "claimed" for a second caller to slip through. A
  separate `in_flight?/1` read followed by a conditional register would have
  exactly that window — which is the shape of race this module exists to
  close, so `with_lock/2` never offers it as two calls.

  Held for the whole of `Promotion.promote/1`, not just the merge: a restart
  that lands after a second promotion's merge is the other half of the same
  race, and QA's build is decided by whichever restart answers last.
  """

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Run `fun` with `project_id`'s lock held, or refuse without running it.

  Returns `{:error, {:already_promoting, started_at}}` immediately, without
  ever calling `fun`, when another process already holds the lock for this
  project. Otherwise claims the lock as the calling process, runs `fun` with
  it held, and releases it afterwards whether `fun` succeeds, returns an
  error tuple, or raises — a promotion that blows up must not leave the
  project permanently locked out from ever promoting again.

  Must be called by the process that will actually do the work: the lock
  lives exactly as long as that process, which is what makes release
  automatic rather than something every caller has to remember.
  """
  @spec with_lock(Ecto.UUID.t(), (-> result)) ::
          result | {:error, {:already_promoting, DateTime.t() | nil}}
        when result: term()
  def with_lock(project_id, fun) when is_function(fun, 0) do
    case Registry.register(__MODULE__, project_id, %{started_at: DateTime.utc_now()}) do
      {:ok, _owner} ->
        try do
          fun.()
        after
          Registry.unregister(__MODULE__, project_id)
        end

      {:error, {:already_registered, _owner_pid}} ->
        {:error, {:already_promoting, in_flight(project_id)}}
    end
  end

  @doc "When the in-flight promotion for `project_id` started, or `nil` if none is running."
  @spec in_flight(Ecto.UUID.t()) :: DateTime.t() | nil
  def in_flight(project_id) do
    case Registry.lookup(__MODULE__, project_id) do
      [{_pid, %{started_at: started_at}}] -> started_at
      [] -> nil
    end
  end
end
