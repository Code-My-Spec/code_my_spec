defmodule CmsHarness.RunLink do
  @moduledoc """
  The harness end of a live run (story 1141), and how a run outlives its
  harness (issue 128c1b27).

  A test run this harness starts joins this node (`ClientUtils.RunLink`) and
  sends each event, numbered by its session, as `{:run_event, run_id, session,
  seq, event}`. Each is acknowledged to that session (`{:run_ack, run_id,
  seq}`), forwarded once to the server on the run's working copy's channel,
  and a replay of one already seen is acknowledged again and dropped. Spex
  shards share a run id and each counts from 1, so a sequence belongs to its
  session.

  A run offers itself with `{:run_rejoin, run_id, node, session}`: on its first
  join, and to whichever harness is listening after this one restarts. It is
  adopted (`{:run_adopted, run_id}`) when this harness expects it (it started
  it) or has claimed it (a run recorded before a restart), and refused
  otherwise, so it goes on looking.

  A run is finished when every shard's `"exit"` event has arrived. Its owner,
  if it named one (`claim/3`), is told `{:run_exited, run_id, status}`.

  Distribution is started on the first run (`CodeMySpec.Analysis.RunNode`).
  """

  use GenServer

  alias CmsHarness.Channel
  alias CodeMySpec.Analysis.RunNode
  alias CodeMySpec.DurableRun

  @halt_after_ms 5_000

  # How long a finished run is kept to acknowledge a replay whose ack was lost:
  # unacknowledged, its run would wait for a harness forever.
  @tombstone_ms :timer.minutes(10)

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
    :ok = GenServer.call(__MODULE__, {:expect, run_id, root, nil})
    RunNode.env(run_id, __MODULE__)
  end

  @doc """
  Adopt a run this harness did not start: one recorded before a restart. The
  `owner` is told `{:run_exited, run_id, status}` when it finishes.
  """
  @spec claim(integer(), String.t(), pid(), GenServer.server()) :: :ok
  def claim(run_id, root, owner, server \\ __MODULE__),
    do: GenServer.call(server, {:expect, run_id, root, owner})

  @doc "Stop a run: asked first, then its node halted if it does not go."
  @spec cancel(integer(), GenServer.server()) :: :ok
  def cancel(run_id, server \\ __MODULE__), do: GenServer.cast(server, {:cancel, run_id})

  @doc """
  Stop every test run of the copy at `root`, because it is deliberately no
  longer served: offboarded, or its directory gone. A harness restarting
  leaves its runs alone, to rejoin the next one; this is the only stop. Each
  recorded run is asked to stop here and at its own node (one whose copy has
  not been served since a restart is claimed by no harness), and its record
  removed so no harness claims it again.
  """
  @spec cancel_copy(String.t(), GenServer.server()) :: :ok
  def cancel_copy(root, server \\ __MODULE__) do
    for %{"run_id" => id} = manifest <- DurableRun.for_root(root),
        manifest["status"] == "running" do
      cancel_at(manifest["node"], id, server)
      cancel(id, server)
      DurableRun.cleanup(id)
    end

    :ok
  end

  @doc """
  Stop a run at its node, adopted or not: a run whose copy is no longer served
  is claimed by no harness, so only its own session can be asked. Its nodes
  are halted after the same grace as `cancel/2` gives (`halt_nodes/2`): a shard
  that has not linked yet has no session to ask.
  """
  @spec cancel_at(String.t() | nil, integer(), GenServer.server()) :: :ok
  def cancel_at(node, run_id, server \\ __MODULE__)
  def cancel_at(nil, _run_id, _server), do: :ok

  def cancel_at(node, run_id, server) when is_binary(node) do
    send({ClientUtils.RunLink.Session, String.to_atom(node)}, {:run_cancel, run_id})
    GenServer.cast(server, {:halt_nodes_later, node})
  end

  @doc """
  Halt a run's nodes by name: its runner, `base`, and its shards,
  `<base>_s<n>` (`Mix.Tasks.Cms.Spex.run_link_env/2`), linked or not. Each is
  a distributed node from VM boot, so one hung before anything links still
  answers. Exact names only: a prefix would reach another run's nodes.
  `:names` and `:cast` are for tests.
  """
  @spec halt_nodes(String.t() | nil, keyword()) :: :ok
  def halt_nodes(base, opts \\ [])
  def halt_nodes(nil, _opts), do: :ok

  def halt_nodes(base, opts) when is_binary(base) do
    names = Keyword.get(opts, :names, &epmd_names/1)
    cast = Keyword.get(opts, :cast, &:erpc.cast/4)
    [name, host] = String.split(base, "@", parts: 2)
    run = ~r/\A#{Regex.escape(name)}(_s\d+)?\z/

    for other <- names.(host),
        Regex.match?(run, other),
        do: cast.(:"#{other}@#{host}", :erlang, :halt, [137])

    :ok
  end

  defp epmd_names(host) do
    case :erl_epmd.names(String.to_charlist(host)) do
      {:ok, names} -> Enum.map(names, fn {name, _port} -> List.to_string(name) end)
      _ -> []
    end
  end

  @doc """
  The run's command has exited. A run that never reported its exit (it
  crashed) finishes here, once.
  """
  @spec exited(integer() | nil, GenServer.server()) :: :ok
  def exited(run_id, server \\ __MODULE__)
  def exited(nil, _server), do: :ok
  def exited(run_id, server), do: GenServer.cast(server, {:exited, run_id})

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:expect, run_id, root, owner}, _from, runs) do
    :ok = RunNode.ensure_started("cms_harness")

    run = %{root: root, owner: owner, sessions: %{}, exits: %{}, shards: 1, finished: false}
    {:reply, :ok, Map.update(runs, run_id, run, &%{&1 | owner: owner || &1.owner})}
  end

  @impl true
  def handle_info({:run_rejoin, run_id, node, session}, runs) do
    case Map.fetch(runs, run_id) do
      {:ok, run} ->
        send(session, {:run_adopted, run_id})
        sessions = Map.put_new(run.sessions, session, %{node: node, seq: 0})
        {:noreply, Map.put(runs, run_id, %{run | sessions: sessions})}

      :error ->
        send(session, {:run_refused, run_id})
        {:noreply, runs}
    end
  end

  def handle_info({:run_event, run_id, session, seq, event}, runs) do
    case Map.fetch(runs, run_id) do
      # Finished: a replay whose ack was lost is acknowledged, never delivered.
      {:ok, %{finished: true}} ->
        send(session, {:run_ack, run_id, seq})
        {:noreply, runs}

      {:ok, run} ->
        send(session, {:run_ack, run_id, seq})
        seen = get_in(run, [:sessions, session, :seq]) || 0

        if seq > seen,
          do: {:noreply, accept(runs, run_id, put_seq(run, session, seq), event)},
          else: {:noreply, runs}

      # Not this harness's run: unacknowledged, so the run keeps looking.
      :error ->
        {:noreply, runs}
    end
  end

  def handle_info({:halt, run_id}, runs) do
    with {:ok, run} <- Map.fetch(runs, run_id) do
      # A cast: a run that heeded the cancel has no node left to answer a call,
      # and the call's `noconnection` was raised in a process of its own.
      for {_session, %{node: node}} <- run.sessions,
          do: :erpc.cast(node, :erlang, :halt, [137])
    end

    {:noreply, runs}
  end

  def handle_info({:halt_nodes, base}, runs) do
    halt_nodes(base)
    {:noreply, runs}
  end

  def handle_info({:forget, run_id}, runs) do
    case Map.fetch(runs, run_id) do
      {:ok, %{finished: true}} -> {:noreply, Map.delete(runs, run_id)}
      _ -> {:noreply, runs}
    end
  end

  def handle_info(_message, runs), do: {:noreply, runs}

  @impl true
  def handle_cast({:cancel, run_id}, runs) do
    with {:ok, %{finished: false} = run} <- Map.fetch(runs, run_id) do
      for {session, _} <- run.sessions, do: send(session, {:run_cancel, run_id})
      Process.send_after(self(), {:halt, run_id}, @halt_after_ms)
    end

    {:noreply, runs}
  end

  def handle_cast({:halt_nodes_later, base}, runs) do
    Process.send_after(self(), {:halt_nodes, base}, @halt_after_ms)
    {:noreply, runs}
  end

  def handle_cast({:exited, run_id}, runs) do
    case Map.fetch(runs, run_id) do
      {:ok, %{finished: false} = run} ->
        deliver(run.root, run_id, %{"event" => "finished"})
        {:noreply, Map.put(runs, run_id, finish(run_id, run))}

      _ ->
        {:noreply, runs}
    end
  end

  defp put_seq(run, session, seq) do
    sessions = Map.update(run.sessions, session, %{node: nil, seq: seq}, &%{&1 | seq: seq})
    %{run | sessions: sessions}
  end

  # The run's exit status, one per shard; the run is finished once all are in.
  defp accept(runs, run_id, run, %{"event" => "exit", "status" => status} = event) do
    run = %{
      run
      | exits: Map.put(run.exits, event["shard"] || 1, status),
        shards: event["shards"] || run.shards
    }

    if map_size(run.exits) >= run.shards do
      # A run that reported its own finish (credo's carries its totals) is not
      # finished again with a bare one.
      unless run[:finished?], do: deliver(run.root, run_id, %{"event" => "finished"})
      worst = run.exits |> Map.values() |> Enum.max()
      if run.owner, do: send(run.owner, {:run_exited, run_id, worst})
      Map.put(runs, run_id, finish(run_id, run))
    else
      Map.put(runs, run_id, run)
    end
  end

  defp accept(runs, run_id, run, event) do
    deliver(run.root, run_id, event)

    Map.put(
      runs,
      run_id,
      Map.put(run, :finished?, run[:finished?] || event["event"] == "finished")
    )
  end

  defp finish(run_id, run) do
    Process.send_after(self(), {:forget, run_id}, @tombstone_ms)
    %{run | finished: true}
  end

  defp deliver(root, run_id, event),
    do: Channel.deliver_analysis_event(root, %{"run_id" => run_id, "event" => event})
end
