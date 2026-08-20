defmodule CodeMySpec.Provisioning.RunLock do
  @moduledoc """
  Which projects have a setup run in flight, right now — and the guard that
  keeps a second one from starting alongside it.

  `run_devops_setup` used to have no way to tell its caller "still working on
  it" — the MCP transport's call timeout is far shorter than a real run
  (deploy alone measured ~167s), so an agent that saw the timeout as failure
  retried, and `Resources.fix/2`/`Provisioning.run/3` had nothing stopping
  the retry from starting a second run against the same project's real
  Cloudflare/Hetzner/Resend/GitHub state while the first was still going.
  Observed live: a step's state flipping `:done -> :errored -> :done` on
  nothing but two runs racing each other's writes, and a genuine Hetzner
  `409 server name is already used` very plausibly from two runs racing the
  same server-creation slot.

  ## Why a Registry, not a database row

  A row would need something to clear it when the holder crashes — a
  supervisor exit that never reaches its `after` block leaves a permanent
  lock nothing can take back. `Registry.register/3` ties the entry to the
  registering process by monitor: it is gone the instant that process is,
  crash or not, and a server restart comes back with an empty table, which is
  true — nothing is running any more. Same reasoning as
  `CodeMySpec.Files.ReconcileRegistry`, which tracks a different kind of
  in-flight work the same way.

  ## The lock is the atomicity, not a check before one

  `Registry.register/3` for `keys: :unique` is a single atomic decision: of
  two processes racing to register the same key, exactly one gets `{:ok, _}`
  and the other gets `{:error, {:already_registered, _}}`, with no window
  between "checked" and "claimed" for a second caller to slip through. A
  separate `in_flight?/1` read followed by a conditional register would have
  exactly that window — which is the shape of race this module exists to
  close, so `with_lock/2` never offers it as two calls.
  """

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Run `fun` with `project_id`'s lock held, or refuse without running it.

  Returns `{:error, {:already_running, started_at}}` immediately, without
  ever calling `fun`, when another process already holds the lock for this
  project. Otherwise claims the lock as the calling process, runs `fun` with
  it held, and releases it afterwards whether `fun` succeeds, returns an
  error tuple, or raises — a run that blows up must not leave the project
  permanently locked out from ever running again.

  Must be called by the process that will actually do the work: the lock
  lives exactly as long as that process, which is what makes release
  automatic rather than something every caller has to remember.
  """
  @spec with_lock(Ecto.UUID.t(), (-> result)) ::
          result | {:error, {:already_running, DateTime.t() | nil}}
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
        {:error, {:already_running, in_flight(project_id)}}
    end
  end

  @doc "When the in-flight run for `project_id` started, or `nil` if none is running."
  @spec in_flight(Ecto.UUID.t()) :: DateTime.t() | nil
  def in_flight(project_id) do
    case Registry.lookup(__MODULE__, project_id) do
      [{_pid, %{started_at: started_at}}] -> started_at
      [] -> nil
    end
  end
end
