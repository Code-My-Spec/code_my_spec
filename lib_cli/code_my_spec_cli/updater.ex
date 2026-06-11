defmodule CodeMySpecCli.Updater do
  @moduledoc """
  Periodic in-process self-update for the server when it runs under a
  supervisor that restarts it on a nonzero exit — i.e. the Windows Shawl
  service (Shawl's default restart-on-nonzero policy).

  Each tick asks `CodeMySpecCli.SelfUpdate.update_in_place/0` to swap the
  on-disk binary if a newer release exists. When it does, this process exits
  the whole VM with a nonzero code and Shawl relaunches the new binary from
  the same path. No service control, no detached respawn, no plugin hook.

  Only started when `CMS_SERVICE=1` (set on the service at registration), so a
  foreground `cms server` or a dev run never restarts itself out from under
  you.
  """

  use GenServer
  require Logger

  alias CodeMySpecCli.SelfUpdate

  # Let the server settle before the first check; then poll a few times a day.
  @initial_delay_ms :timer.minutes(5)
  @interval_ms :timer.hours(6)

  # Any nonzero exit triggers Shawl's default restart. Distinct from a crash
  # so it's recognizable in Shawl's log.
  @restart_exit_code 70

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule(@initial_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    case safe_check() do
      :updated ->
        Logger.info(
          "cms updater: new binary swapped in; exiting #{@restart_exit_code} for supervisor restart"
        )

        System.halt(@restart_exit_code)

      _ ->
        schedule(@interval_ms)
        {:noreply, state}
    end
  end

  defp safe_check do
    SelfUpdate.update_in_place()
  rescue
    e ->
      Logger.warning("cms updater: check failed — #{Exception.message(e)}")
      :error
  end

  defp schedule(ms), do: Process.send_after(self(), :check, ms)
end
