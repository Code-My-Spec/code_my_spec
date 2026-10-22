defmodule CmsHarness.RunLink do
  @moduledoc """
  The harness end of a live run (story 1141).

  A test run this harness starts joins this node (`ClientUtils.RunLink`) and
  sends each event here as it happens; each is forwarded to the server on the
  run's working copy's channel. The run watches this process and halts when it
  goes, so a run never outlives the harness that started it.

  Distribution is started on the first run, at `<name>@127.0.0.1`: a harness
  that never runs a suite never opens a port.
  """

  use GenServer

  require Logger

  alias CmsHarness.Channel

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @doc """
  What a run started for `run_id` in `root` needs in its environment to report
  here. No run id, no link: the run is a plain `mix test`.
  """
  @spec env(String.t(), integer() | nil) :: [{String.t(), String.t()}]
  def env(_root, nil), do: []

  def env(root, run_id) when is_integer(run_id) do
    if Process.whereis(__MODULE__), do: link_env(root, run_id), else: []
  end

  defp link_env(root, run_id) do
    :ok = GenServer.call(__MODULE__, {:expect, run_id, root})

    [
      {"CMS_HARNESS_NODE", Atom.to_string(node())},
      {"CMS_HARNESS_COOKIE", Atom.to_string(Node.get_cookie())},
      {"CMS_RUN_ID", Integer.to_string(run_id)}
    ]
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:expect, run_id, root}, _from, runs) do
    :ok = distribute()
    {:reply, :ok, Map.put(runs, run_id, root)}
  end

  @impl true
  def handle_info({:run_event, run_id, event}, runs) do
    case Map.fetch(runs, run_id) do
      {:ok, root} ->
        Channel.deliver_analysis_event(root, %{"run_id" => run_id, "event" => event})
        {:noreply, forget_finished(runs, run_id, event)}

      :error ->
        {:noreply, runs}
    end
  end

  def handle_info(_message, runs), do: {:noreply, runs}

  defp forget_finished(runs, run_id, %{"event" => "finished"}), do: Map.delete(runs, run_id)
  defp forget_finished(runs, _run_id, _event), do: runs

  defp distribute do
    if Node.alive?(), do: :ok, else: start_node()
  end

  # `Node.start/2` registers with epmd; a machine whose epmd is not running
  # gets one started, once.
  defp start_node do
    name = :"cms_harness_#{System.pid()}@127.0.0.1"

    case Node.start(name, :longnames) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[CmsHarness] starting distribution failed (#{inspect(reason)}); starting epmd"
        )

        System.cmd("epmd", ["-daemon"])
        {:ok, _pid} = Node.start(name, :longnames)
        :ok
    end
  end
end
