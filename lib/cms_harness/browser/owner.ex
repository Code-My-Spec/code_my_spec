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

  It also keeps notes for the copy's next browser call. A dialog dismissed
  after a call timed out is reported on the next answer
  (`CmsHarness.Browser.Dialog`).
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

  @doc "Leave a note for this copy's next browser call."
  @spec leave_note(String.t(), String.t()) :: :ok
  def leave_note(root, note), do: GenServer.cast(via(root), {:leave_note, note})

  @doc "The notes left since the last call, oldest first. Each is handed out once."
  @spec take_notes(String.t()) :: [String.t()]
  def take_notes(root) do
    case GenServer.whereis(via(root)) do
      nil -> []
      pid -> GenServer.call(pid, :take_notes, 15_000)
    end
  end

  @impl true
  def init(root) do
    Process.flag(:trap_exit, true)
    {:ok, %{root: root, notes: []}}
  end

  @impl true
  def handle_call({:connect, path}, _from, state) do
    {:reply, Browser.connect(state.root, path), state}
  end

  def handle_call(:take_notes, _from, state) do
    {:reply, Enum.reverse(state.notes), %{state | notes: []}}
  end

  @impl true
  def handle_cast({:leave_note, note}, state),
    do: {:noreply, %{state | notes: [note | state.notes]}}

  # The exit of a client supervisor that failed to start, or one unlinked a
  # moment too late. Neither is this process's to die of.
  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Browser.disconnect(state.root)
end
