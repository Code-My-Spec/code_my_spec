defmodule CodeMySpec.Files.LockfileSweep do
  @moduledoc """
  Periodic backstop for `FileSync.reconcile_lockfile/1` (577de9bb step 3).

  The live trigger — a `:lockfile` entry landing in a manifest — covers
  every case where the lock actually changes while its harness is
  connected. It cannot cover a reconcile that found a changed fingerprint
  and then lost the harness before it finished reading the content: that
  project's `mix_lock_fingerprint` is left stale, and nothing about *that*
  lock changes again to re-trigger it.

  So something has to ask again on its own schedule rather than waiting to
  be told. Every `@interval_ms`, this calls `reconcile_lockfile/1` for every
  project with a main copy, whether or not anything changed recently —
  cheap, because the function itself re-derives "does this actually need
  doing" from stored state before touching the harness.

  Also the backstop for `FileSync.reconcile_project_knowledge/1` (step 5),
  for the same reason: a knowledge file left pending by an offline harness
  has nothing else to re-trigger it.
  """

  use GenServer

  require Logger

  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.WorkingCopies

  @interval_ms :timer.minutes(15)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run one sweep now, synchronously, across every project with a main copy.

  For the periodic timer and for tests — spex fixtures project a realistic
  `files` row plus a main copy and call this directly rather than waiting
  on a real clock.
  """
  @spec sweep_now() :: :ok
  def sweep_now do
    WorkingCopies.main_copy_scopes()
    |> Enum.each(&reconcile_one/1)

    :ok
  end

  defp reconcile_one(scope) do
    guarded(scope, &FileSync.reconcile_lockfile/1)
    guarded(scope, &FileSync.reconcile_project_knowledge/1)
  end

  defp guarded(scope, reconcile) do
    reconcile.(scope)
  rescue
    e ->
      Logger.error(
        "[LockfileSweep] #{scope.active_project_id}: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
  end

  @impl GenServer
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)
    schedule(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep_now()
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)
end
