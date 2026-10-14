defmodule CodeMySpecDesktop.Application.Shell do
  @moduledoc "Supervises the setup window independently of database-dependent services."
  use Supervisor

  alias CodeMySpecDesktop.Application.{Bootstrap, Runtime, SetupPlug}

  def start_link(opts) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    opts = Keyword.put(opts, :token, token)

    with {:ok, supervisor} <- Supervisor.start_link(__MODULE__, opts) do
      open_window(supervisor, token, Keyword.fetch!(opts, :view))
    end
  end

  @impl true
  def init(opts) do
    bootstrap = Keyword.get(opts, :bootstrap, Bootstrap)
    tasks = Keyword.get(opts, :tasks, CodeMySpecDesktop.SetupTasks)

    runtime_supervisor =
      Keyword.get(opts, :runtime_supervisor, CodeMySpecDesktop.RuntimeSupervisor)

    http =
      Supervisor.child_spec(
        {Bandit,
         plug: {SetupPlug, bootstrap: bootstrap, token: opts[:token], app_url: opts[:app_url]},
         ip: {127, 0, 0, 1},
         port: 0},
        id: :setup_http
      )

    children = [
      {Task.Supervisor, name: tasks},
      {DynamicSupervisor, name: runtime_supervisor, strategy: :one_for_one},
      {Bootstrap,
       name: bootstrap,
       tasks: tasks,
       runtime_supervisor: runtime_supervisor,
       setup_opts: Keyword.get(opts, :setup_opts, []),
       runtime: Keyword.get(opts, :runtime, Runtime)},
      http
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp open_window(supervisor, token, view) do
    {:setup_http, listener, _, _} =
      supervisor |> Supervisor.which_children() |> Enum.find(&(elem(&1, 0) == :setup_http))

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    url = "http://127.0.0.1:#{port}/setup/#{token}"

    case Supervisor.start_child(supervisor, view.(url)) do
      {:ok, _window} ->
        {:ok, supervisor}

      {:ok, _window, _info} ->
        {:ok, supervisor}

      {:error, reason} ->
        Supervisor.stop(supervisor)
        {:error, reason}
    end
  end
end
