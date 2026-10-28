defmodule CodeMySpec.Analysis.BootRecovery do
  @moduledoc """
  Reconcile runs from the previous server before the endpoint accepts a harness join.

  A returning harness can reclaim its remote runs during the grace period.
  """

  use GenServer

  alias CodeMySpec.Analysis

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    booted_at = DateTime.utc_now()
    {:ok, _failed} = Analysis.settle_stranded_runs()

    Process.send_after(
      self(),
      :abandon_unclaimed,
      Application.get_env(:code_my_spec, :analysis_restart_grace_ms, 60_000)
    )

    {:ok, booted_at}
  end

  @impl true
  def handle_info(:abandon_unclaimed, booted_at) do
    Analysis.abandon_unclaimed_after_restart(booted_at)
    {:stop, :normal, booted_at}
  end
end
