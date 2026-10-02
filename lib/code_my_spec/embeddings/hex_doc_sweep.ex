defmodule CodeMySpec.Embeddings.HexDocSweep do
  @moduledoc """
  Periodic driver for `HexDocReconciler.reconcile_all/0` (577de9bb step 3).

  Unlike the lockfile trigger's sweep, there is no separate "live" event to
  react to here — a new pending `{package, version}` appears the moment
  `FileSync.reconcile_lockfile/1` records it, with nothing else watching for
  that. So this is not a backstop for a live trigger that usually fires; it
  is the trigger, on a short interval because the gap between a lock
  changing and its docs being searchable is itself the thing step 3 exists
  to shrink.
  """

  use GenServer

  require Logger

  alias CodeMySpec.Embeddings.HexDocReconciler

  @interval_ms :timer.minutes(2)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run one sweep now, synchronously, across every pending package@version.

  For the periodic timer and for tests — spex fixtures project a realistic
  `project_dependencies` state and recorded hex tarball fixtures and call
  this directly rather than waiting on a real clock.
  """
  @spec sweep_now() :: :ok
  def sweep_now do
    HexDocReconciler.reconcile_all()
  rescue
    e ->
      Logger.error("[HexDocSweep] " <> Exception.format(:error, e, __STACKTRACE__))
      :ok
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
