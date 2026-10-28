defmodule CodeMySpecTest.LiveAsync do
  @moduledoc """
  Render a LiveView once its async work has finished, waiting on the work
  itself: `render_async/2` gives up after a fixed window, which a loaded gate
  outlasts.
  """

  # Not a window to race: work this late is hung, and saying so beats the
  # test's own timeout.
  @hung 30_000

  @spec render_settled(Phoenix.LiveViewTest.View.t()) :: String.t()
  def render_settled(view) do
    {:ok, pids} = Phoenix.LiveView.Channel.async_pids(view.pid)

    pids
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        @hung -> raise "async work in #{inspect(view.module)} still running after #{@hung}ms"
      end
    end)

    Phoenix.LiveViewTest.render(view)
  end
end
