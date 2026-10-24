defmodule CodeMySpecDesktop.Application.Shell do
  @moduledoc "Starts the SQLite runtime, then opens the application window at /app."
  use Supervisor

  alias CodeMySpecDesktop.Application.Runtime

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    runtime = Keyword.get(opts, :runtime, Runtime)
    view = Keyword.fetch!(opts, :view)
    url = Keyword.fetch!(opts, :app_url)

    Supervisor.init([{runtime, []}, view.(url)], strategy: :rest_for_one)
  end
end
