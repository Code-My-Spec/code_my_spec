defmodule CodeMySpecWeb.TelemetryHandlers do
  @moduledoc """
  Puts back any telemetry handler that has come off.

  `:telemetry` detaches a handler the first time it raises, for good. A hot
  reload has a window in which a handler's module is not loaded, and an event
  fired in it raises `:undef`: on 2026-10-28 at 10:26:46 that detached
  `AnalysisReport`, and no agent was told a run had finished until the app
  restarted. Every attach here is idempotent (`{:error, :already_exists}` while
  attached), so this re-runs them on an interval and names any that answered
  `:ok`, which means it had been detached.
  """

  use GenServer

  require Logger

  @interval :timer.seconds(30)

  @spec start_link([{String.t(), (-> :ok | {:error, term()})}], keyword()) ::
          GenServer.on_start()
  def start_link(attachers, opts \\ [name: __MODULE__]),
    do: GenServer.start_link(__MODULE__, attachers, opts)

  @doc "Check every handler now, returning the names that had to be re-attached."
  @spec check(GenServer.server()) :: [String.t()]
  def check(server \\ __MODULE__), do: GenServer.call(server, :check)

  @impl true
  def init(attachers) do
    schedule()
    {:ok, attachers}
  end

  @impl true
  def handle_call(:check, _from, attachers), do: {:reply, reattach(attachers), attachers}

  @impl true
  def handle_info(:check, attachers) do
    reattach(attachers)
    schedule()
    {:noreply, attachers}
  end

  defp reattach(attachers) do
    for {name, attach} <- attachers, attach.() == :ok do
      Logger.warning(
        "[Telemetry] #{name} had been detached (it raised, as during a hot reload) and is attached again"
      )

      name
    end
  end

  defp schedule, do: Process.send_after(self(), :check, @interval)
end
