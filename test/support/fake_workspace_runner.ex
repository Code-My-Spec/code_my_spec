defmodule CodeMySpecTest.FakeWorkspaceRunner do
  @moduledoc """
  A `CodeMySpec.Workspaces.Runner` whose answers the test decides.

  Booting a real devbox takes minutes and needs a Docker daemon, so the
  outcomes the story cares about — it came up, it died, it never answered —
  are driven from here instead.
  """

  use Agent

  @behaviour CodeMySpec.Workspaces.Runner

  @doc "Starts the fake with the outcomes this test wants."
  def start_link(opts) do
    state = %{
      start_result: Keyword.get(opts, :start_result, :ok),
      healthy?: Keyword.get(opts, :healthy?, true),
      serving: Keyword.get(opts, :serving, :serving),
      alive?: Keyword.get(opts, :alive?, true),
      logs: Keyword.get(opts, :logs, ""),
      calls: []
    }

    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  @doc "Replaces what the container has announced so far."
  def put_logs(logs), do: Agent.update(__MODULE__, &%{&1 | logs: logs})

  @doc "Sets what the app is doing: :serving, :erroring or :down."
  def put_serving(serving) when serving in [:serving, :erroring, :down, :ok] do
    Agent.update(__MODULE__, &%{&1 | serving: normalize(serving)})
  end

  defp normalize(:ok), do: :serving
  defp normalize(other), do: other

  @doc """
  Decides, from the test, whether the instance is answering yet.

  Lets a test observe the booting state and then end it deliberately, instead
  of racing the watcher's wall-clock deadline — a race the test loses on a
  loaded machine, which is exactly where it must not be flaky.
  """
  def put_healthy(healthy?), do: Agent.update(__MODULE__, &%{&1 | healthy?: healthy?})

  @doc "Kills the instance from the test — the container has gone away."
  def put_alive(alive?), do: Agent.update(__MODULE__, &%{&1 | alive?: alive?})

  @doc "Every `start/3` the context made, oldest first."
  def calls, do: __MODULE__ |> Agent.get(& &1.calls) |> Enum.reverse()

  @impl true
  def start(container_name, app_name, port) do
    Agent.get_and_update(__MODULE__, fn state ->
      {state.start_result,
       %{state | calls: [{container_name, app_name, port} | state.calls]}}
    end)
  end

  @impl true
  def healthy?(_port), do: Agent.get(__MODULE__, & &1.healthy?)

  @impl true
  def serving(_port), do: Agent.get(__MODULE__, & &1.serving)

  @impl true
  def url(_container_name, port), do: "http://localhost:#{port}"

  # Config wins over the agent's own state when set, so a spex can kill the
  # instance mid-run without calling across a boundary into this module.
  @impl true
  def alive?(_container_name) do
    case Application.get_env(:code_my_spec, :fake_workspace_alive) do
      nil -> Agent.get(__MODULE__, & &1.alive?)
      alive? -> alive?
    end
  end

  @impl true
  def logs(_container_name), do: Agent.get(__MODULE__, & &1.logs)

  @impl true
  def stop(_container_name), do: :ok
end
