defmodule CodeMySpec.Agents.Mailbox.Reconciler do
  @moduledoc "Backstop for missed delivery wakeups. State is in the database, not this process."
  use GenServer
  require Logger

  alias CodeMySpec.Agents.Mailbox
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts) do
    send(self(), :reconcile)
    {:ok, nil}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Mailbox.reconcile_pending()
    Process.send_after(self(), :reconcile, 30_000)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Mailbox reconciliation failed: #{Exception.message(error)}")
      Process.send_after(self(), :reconcile, 30_000)
      {:noreply, state}
  end
end
