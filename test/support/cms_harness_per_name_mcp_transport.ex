defmodule CmsHarnessTest.PerNameMcpTransport do
  @moduledoc """
  An MCP transport with `Anubis.Client`'s shape and nothing else.

  `connect/2` links an anonymous supervisor to the caller, holding a client
  registered under the name it was given, and unlinks it once up. A second
  start under a held name fails the supervisor with
  `{:shutdown, {:failed_to_start_child, Anubis.Client, {:already_started, pid}}}`,
  and the linked exit takes a caller that is not trapping exits down with it —
  which is what the real one does. No subprocess, no vibium.

  Every connect waits at `Barrier` until as many have arrived as it was started
  with, so N copies really do connect at the same moment.
  """

  @behaviour CmsHarness.Mcp.Transport

  defmodule Barrier do
    @moduledoc "Holds connects until `n` have arrived, and counts them."
    use GenServer

    def start_link(n), do: GenServer.start_link(__MODULE__, n, name: __MODULE__)
    def arrive, do: GenServer.call(__MODULE__, :arrive, 2_000)
    def connects, do: GenServer.call(__MODULE__, :connects)

    @impl true
    def init(n), do: {:ok, %{n: n, waiting: [], connects: 0}}

    @impl true
    def handle_call(:connects, _from, state), do: {:reply, state.connects, state}

    def handle_call(:arrive, from, state) do
      state
      |> Map.update!(:waiting, &[from | &1])
      |> Map.update!(:connects, &(&1 + 1))
      |> release()
    end

    defp release(%{n: n, waiting: waiting} = state) when length(waiting) >= n do
      Enum.each(waiting, &GenServer.reply(&1, :ok))
      {:noreply, %{state | waiting: []}}
    end

    defp release(state), do: {:noreply, state}
  end

  defmodule Client do
    @moduledoc false
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

    @impl true
    def init(name), do: {:ok, name}
  end

  defmodule ClientTree do
    @moduledoc false
    use Supervisor

    def start_link(name), do: Supervisor.start_link(__MODULE__, name)

    @impl true
    def init(name) do
      Supervisor.init([%{id: Anubis.Client, start: {Client, :start_link, [name]}}],
        strategy: :one_for_all
      )
    end
  end

  @impl true
  def connect(name, _opts) do
    Barrier.arrive()

    with {:ok, sup} <- ClientTree.start_link(name) do
      Process.unlink(sup)
      {:ok, name}
    end
  end

  @impl true
  def call(client, tool, args), do: call(client, tool, args, [])

  # Answers with the pid of the client it reached, so a test can see which
  # session a call went to.
  @impl true
  def call(client, _tool, _args, _opts), do: {:ok, inspect(GenServer.whereis(client))}

  @impl true
  def list_tool_names(client) do
    with {:ok, tools} <- list_tools(client), do: {:ok, Enum.map(tools, & &1["name"])}
  end

  @impl true
  def list_tools(client), do: client |> GenServer.whereis() |> tools()

  defp tools(pid) when is_pid(pid),
    do: {:ok, [%{"name" => "browser_navigate", "description" => "Go to a URL"}]}

  defp tools(nil), do: {:error, :no_client}

  @impl true
  def disconnect(client), do: client |> GenServer.whereis() |> stop()

  defp stop(pid) when is_pid(pid) do
    {:parent, sup} = Process.info(pid, :parent)
    Supervisor.stop(sup, :normal)
  end

  defp stop(nil), do: :ok
end
