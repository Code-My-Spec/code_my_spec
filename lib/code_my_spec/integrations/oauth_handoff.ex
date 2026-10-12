defmodule CodeMySpec.Integrations.OAuthHandoff do
  @moduledoc """
  Holds an OAuth flow's state between the desktop window that starts it and
  the system browser that finishes it (bb8bc042).

  The cloud app keeps Assent's `session_params` (state, PKCE verifier) in the
  session cookie. On the desktop that cookie belongs to the window, but the
  provider's page has to open in the user's browser — Google refuses OAuth in
  an embedded webview — and the browser's callback carries a different cookie
  jar. So the window parks the flow here under its `state`, and the callback
  claims it by the `state` the provider echoes back. Each entry is taken once
  and expires after ten minutes.
  """

  use GenServer

  @ttl_ms :timer.minutes(10)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, :ok)
      name -> GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  @doc "Park a flow under its state."
  @spec park(GenServer.server(), map()) :: :ok
  def park(server \\ __MODULE__, %{session_params: %{state: state}} = flow) when is_binary(state),
    do: GenServer.call(server, {:park, state, flow})

  @doc "Take the flow parked under `state`, once."
  @spec claim(GenServer.server(), String.t() | nil) :: {:ok, map()} | :error
  def claim(server \\ __MODULE__, state)
  def claim(server, state) when is_binary(state), do: GenServer.call(server, {:claim, state})
  def claim(_server, _state), do: :error

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:park, state, flow}, _from, flows) do
    Process.send_after(self(), {:expire, state}, @ttl_ms)
    {:reply, :ok, Map.put(flows, state, flow)}
  end

  def handle_call({:claim, state}, _from, flows) do
    case Map.pop(flows, state) do
      {nil, flows} -> {:reply, :error, flows}
      {flow, flows} -> {:reply, {:ok, flow}, flows}
    end
  end

  @impl true
  def handle_info({:expire, state}, flows), do: {:noreply, Map.delete(flows, state)}
end
