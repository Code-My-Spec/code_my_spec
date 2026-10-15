defmodule CmsHarness.AppInstance.LogTrimmer do
  @moduledoc """
  Trims every app instance's log on its own timer.

  The trim ran on the instance's status tick, and that tick only starts once
  an instance has gone half an hour without a call. An app asked about every
  few seconds, like :4000, never ticked, so its log was back past 140 MB an
  hour after the trim landed (2026-10-15).
  """

  use GenServer

  alias CmsHarness.AppInstance
  alias CmsHarness.AppInstance.LogTrim

  @max_bytes 50 * 1024 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Trim each instance's `app.log` under `root` that is past `max_bytes`."
  @spec trim_all(Path.t(), non_neg_integer()) :: :ok
  def trim_all(root, max_bytes \\ @max_bytes) do
    root
    |> Path.join("*/app.log")
    |> Path.wildcard()
    |> Enum.each(&LogTrim.trim(&1, max_bytes))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, to_timeout(minute: 2))
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:trim, state) do
    trim_all(AppInstance.instances_root())
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(:never), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :trim, interval)
end
