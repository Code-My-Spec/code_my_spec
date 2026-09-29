defmodule CmsHarness.Browser.Owner do
  @moduledoc """
  The process one working copy's browser session belongs to.

  A child of the copy's `CmsHarness.Project.Supervisor`, ahead of the channel
  client, so the session survives a reconnect and goes when the copy does.

  Connects for this copy run here, one at a time: the join's probe and an
  agent's first `tool_call` can arrive together, and two connects under one
  name is the `:already_started` collision `CmsHarness.Browser` exists to avoid.
  Traps exits because `Anubis.Client.start_link/1` links its supervisor to the
  caller, and a failed start must come back as an error rather than take this
  process — and with it the copy's subtree — down.
  """

  use GenServer

  alias CmsHarness.Browser

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}
  end

  def start_link(opts) do
    root = Keyword.fetch!(opts, :root)
    GenServer.start_link(__MODULE__, root, name: via(root))
  end

  defp via(root), do: {:via, Registry, {CmsHarness.Registry, {:browser_owner, root}}}

  @doc "Connect this copy's browser session through its owner."
  @spec connect(String.t(), String.t()) :: {:ok, GenServer.name()} | {:error, term()}
  def connect(root, path) do
    case GenServer.whereis(via(root)) do
      nil -> {:error, :not_serving}
      pid -> GenServer.call(pid, {:connect, path}, 15_000)
    end
  end

  @impl true
  def init(root) do
    Process.flag(:trap_exit, true)
    {:ok, root}
  end

  @impl true
  def handle_call({:connect, path}, _from, root) do
    {:reply, Browser.connect(root, path), root}
  end

  # The exit of a client supervisor that failed to start, or one unlinked a
  # moment too late. Neither is this process's to die of.
  @impl true
  def handle_info({:EXIT, _pid, _reason}, root), do: {:noreply, root}

  @impl true
  def terminate(_reason, root), do: Browser.disconnect(root)
end
