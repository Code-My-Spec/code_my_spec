defmodule CmsHarness.Agents.Engine do
  @moduledoc """
  An agent, as a supervised process on the machine that holds its working copy.

  Replaces starting `pi` as a detached OS process. The difference is not an
  implementation detail — it is why several problems stop existing:

    * **Sending it a message** was a held stdin pipe, a FIFO with a writer
      inside the agent's own process group so it never saw EOF, and a
      reverse-engineered rpc protocol. It is now `chat/2`.
    * **Stopping it** was one signal to a process group, keyed on a group id
      recorded beside the boot it belonged to so a recycled number could not be
      mistaken for ours. It is now termination.
    * **Knowing it is alive** was a reaper comparing group ids against a boot
      id, because a process id proves a fork and nothing else. It is now
      `Process.alive?/1`.

  ## Why here rather than on the server

  The working copy is here. An agent session is hundreds of read, edit and bash
  calls, and server-side every one of them would be a channel round-trip with a
  timeout and its own failure mode — a dropped channel mid-call becoming a
  broken turn rather than a deferred sync. `Alloy`'s core tools take a
  `:working_directory` in their context and operate on a local disk, which is
  what this is.

  The isolation the hosted product needs is the sprite boundary, and that is
  already a boundary: filesystem, credential, network and CPU per tenant. A
  server-side loop would run every tenant's tool calls inside one BEAM instead.

  ## What it costs, and what pays for it

  An agent dies with the harness. That was fatal with a detached OS process,
  because resurrecting one meant process groups and boot ids. Here the
  transcript is the state: `Alloy.Agent.Server` accepts `:messages`, and turns
  are already persisted server-side, so coming back is starting a process with
  the history it had.

  Agent *behaviour* ships in the harness release, which is the real cost. The
  mitigation is to keep only the loop here and let prompts, skills and the tool
  manifest arrive as data at start — the loop is stable, the behaviour is not.
  """

  use GenServer, restart: :temporary

  require Logger

  alias CmsHarness.Agents.Provider

  @registry CmsHarness.Registry
  @supervisor CmsHarness.AgentSupervisor

  @type start_opts :: [
          agent_id: String.t(),
          provider: String.t(),
          credential: map(),
          working_copy: String.t(),
          model: String.t() | nil,
          base_url: String.t() | nil,
          on_stop: (-> any()) | nil,
          on_event: (map() -> any()) | nil
        ]

  # ---------------------------------------------------------------- public API

  @doc """
  Start an agent for this request, under the harness's agent supervisor.

  Returns the agent id it is registered under. There is no process group and no
  boot id: the id is the handle, and it is only meaningful while this harness
  is running — which is the honest scope, rather than a number that outlives
  the thing that can interpret it.
  """
  @spec start(start_opts()) :: {:ok, %{agent_id: String.t(), pid: pid()}} | {:error, term()}
  def start(opts) do
    with {:ok, agent_id} <- require_opt(opts, :agent_id),
         {:ok, working_copy} <- require_opt(opts, :working_copy),
         :ok <- working_copy_exists(working_copy),
         {:ok, _alloy_opts} <- alloy_options(opts) do
      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
        {:ok, pid} ->
          Logger.info("[CmsHarness] agent #{agent_id} running in #{working_copy}")
          {:ok, %{agent_id: agent_id, pid: pid}}

        {:error, {:already_started, pid}} ->
          {:ok, %{agent_id: agent_id, pid: pid}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Send a message to a running agent and wait for its turn to finish.

  This is the whole of what a held stdin pipe was for.
  """
  @spec chat(String.t(), String.t(), timeout()) ::
          {:ok, term()} | {:ok, {:queued, String.t()}} | {:error, term()}
  def chat(agent_id, message, timeout \\ 180_000) do
    with {:ok, pid} <- whereis(agent_id) do
      GenServer.call(pid, {:chat, message, timeout}, timeout + 5_000)
    end
  end

  @doc """
  Give a running agent something to do without waiting for the turn.

  `chat/3` answers when the turn is over, which is what a caller at an MCP tool
  wants and the wrong shape for a person at a page: a turn is minutes, and a
  page that waited one out looks broken. The answer arrives the same way
  everything else the agent does arrives — as turn events, in the transcript
  they are already reading.

  `ref` names the message, which is what makes it withdrawable: without one,
  taking something back means describing it, and two identical messages become
  indistinguishable at the moment it matters.
  """
  @spec send_message(String.t(), String.t(), String.t(), timeout()) ::
          {:ok, :started | :queued} | {:error, term()}
  def send_message(agent_id, ref, message, timeout \\ 180_000) do
    with {:ok, pid} <- whereis(agent_id) do
      GenServer.call(pid, {:send, ref, message, timeout})
    end
  end

  @doc """
  Take back a message the agent has not picked up yet.

  `{:error, :already_delivered}` when it has. That refusal is the point: a turn
  ends while somebody is reaching for the control, and reporting success there
  leaves them believing the agent was stopped while it acts on the thing they
  thought they took back.
  """
  @spec withdraw(String.t(), String.t()) ::
          :ok | {:error, :already_delivered | :not_running}
  def withdraw(agent_id, ref) do
    with {:ok, pid} <- whereis(agent_id) do
      GenServer.call(pid, {:withdraw, ref})
    end
  end

  @doc """
  What this agent is doing right now.

  `busy?` is whether a turn is in flight and `queued` is what is stacked behind
  it. The row cannot answer either: it says an agent is running, which is true
  of one thinking and one waiting, and those are the two states somebody
  watching wants told apart.
  """
  @spec status(String.t()) ::
          {:ok, %{busy?: boolean(), queued: non_neg_integer()}} | {:error, :not_running}
  def status(agent_id) do
    with {:ok, pid} <- whereis(agent_id) do
      GenServer.call(pid, :status)
    end
  end

  @doc """
  Stop one agent.

  One, and only one — a stop that reaps a tree, or matches by name and catches
  a sibling, is indistinguishable from this at the call site and is worse than
  having no stop at all. The agents left alone are the point.
  """
  @spec stop(String.t()) :: :ok | {:error, :not_running}
  def stop(agent_id) do
    case whereis(agent_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(@supervisor, pid)
      {:error, _} = error -> error
    end
  end

  @doc """
  Agent ids this harness is running.

  Read from the registry rather than from anything we were told, so it cannot
  disagree with what is actually alive — the failure mode that made a reaper
  necessary in the first place.
  """
  @spec running() :: [String.t()]
  def running do
    @registry
    |> Registry.select([{{{:agent, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
    |> Enum.map(fn {id, _pid} -> id end)
  end

  @doc "Whether this agent is running here."
  @spec running?(String.t()) :: boolean()
  def running?(agent_id), do: match?({:ok, _pid}, whereis(agent_id))

  @spec child_spec(start_opts()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :agent_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.start_link(__MODULE__, opts, name: via(agent_id))
  end

  # ------------------------------------------------------------------ callbacks

  @impl true
  def init(opts) do
    {:ok, alloy_opts} = alloy_options(opts)

    case Alloy.Agent.Server.start_link(alloy_opts) do
      {:ok, alloy} ->
        Process.flag(:trap_exit, true)

        {:ok,
         %{
           agent_id: Keyword.fetch!(opts, :agent_id),
           working_copy: Keyword.fetch!(opts, :working_copy),
           provider: Keyword.fetch!(opts, :provider),
           on_stop: Keyword.get(opts, :on_stop),
           on_event: Keyword.get(opts, :on_event),
           alloy: alloy,
           # The turn in flight, or nil. One at a time — an agent working two
           # turns at once in one checkout is two agents editing one tree.
           turn: nil,
           # What is waiting for it, oldest first.
           queue: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Idle, so the turn starts now and this caller waits it out.
  @impl true
  def handle_call({:chat, message, timeout}, from, %{turn: nil} = state) do
    {:noreply, %{state | turn: start_turn(state, new_ref(), message, timeout, from)}}
  end

  # Busy. Waiting is the answer rather than blocking: holding the caller would
  # make them wait two turns for one, and the ref is what lets them change
  # their mind in the meantime.
  def handle_call({:chat, message, timeout}, _from, state) do
    ref = new_ref()
    {:reply, {:ok, {:queued, ref}}, enqueue(state, ref, message, timeout)}
  end

  def handle_call({:send, ref, message, timeout}, _from, %{turn: nil} = state) do
    {:reply, {:ok, :started}, %{state | turn: start_turn(state, ref, message, timeout, nil)}}
  end

  def handle_call({:send, ref, message, timeout}, _from, state) do
    {:reply, {:ok, :queued}, enqueue(state, ref, message, timeout)}
  end

  # Only what is still waiting can be taken back. Anything else the agent
  # already has, and there is no unsaying it — so this says so instead of
  # clearing a queue entry that is not there and reporting success.
  def handle_call(:status, _from, state) do
    {:reply, {:ok, %{busy?: state.turn != nil, queued: length(state.queue)}}, state}
  end

  def handle_call({:withdraw, ref}, _from, state) do
    case Enum.split_with(state.queue, &(&1.ref == ref)) do
      {[], _keep} -> {:reply, {:error, :already_delivered}, state}
      {_taken, keep} -> {:reply, :ok, %{state | queue: keep}}
    end
  end

  # The turn answered.
  @impl true
  def handle_info({task_ref, result}, %{turn: %{task: %Task{ref: task_ref}}} = state) do
    Process.demonitor(task_ref, [:flush])
    settle(state, result)
  end

  # The turn died. Whoever was waiting hears why rather than waiting out a
  # timeout, and the agent stays up: one turn failing is not the agent failing,
  # and killing it here would lose everything queued behind it.
  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %{turn: %{task: %Task{ref: task_ref}}} = state
      ) do
    settle(state, {:error, reason})
  end

  # The loop this agent *is* went away. Nothing is left to be an agent with, so
  # this goes too rather than staying registered as something that will accept
  # a message and can never answer it.
  def handle_info({:EXIT, alloy, reason}, %{alloy: alloy} = state) do
    {:stop, reason, state}
  end

  # A task exiting, arriving here because this process traps exits. The `DOWN`
  # above is what acts on it; this keeps a normal completion from being logged
  # as something unexpected.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Asked, not killed.
  #
  # A supervisor shutdown runs this; a brutal kill does not. That difference is
  # the whole of "a stop asks the agent to finish what it is doing before it
  # insists" — anything the agent was part-way through gets to land here rather
  # than being lost with the process.
  @impl true
  def terminate(_reason, state) do
    run_on_stop(state.on_stop)
    Logger.info("[CmsHarness] agent #{state.agent_id} stopped")
    :ok
  end

  defp run_on_stop(fun) when is_function(fun, 0), do: fun.()
  defp run_on_stop(_), do: :ok

  # -------------------------------------------------------------------- private

  # A turn, running where it cannot make the agent unreachable.
  #
  # In a task rather than in `handle_call` because an agent that cannot answer
  # while it works cannot be sent anything while it works — and mid-turn is
  # when an operator most wants to. Linked, and this process traps exits, so a
  # turn that crashes arrives as a message instead of taking the agent with it.
  defp start_turn(state, ref, message, timeout, awaiting) do
    announce_delivery(state, ref)

    %{
      task: Task.async(fn -> run_turn(state, message, timeout) end),
      awaiting: awaiting,
      ref: ref
    }
  end

  defp enqueue(state, ref, message, timeout) do
    %{state | queue: state.queue ++ [%{ref: ref, message: message, timeout: timeout}]}
  end

  # A turn ended: whoever was waiting hears about it, and whatever was waiting
  # goes next. In the order it was sent, because the second thing an operator
  # says usually assumes the first.
  defp settle(state, result) do
    reply_to(state.turn.awaiting, result)
    drain(%{state | turn: nil})
  end

  defp drain(%{queue: []} = state), do: {:noreply, state}

  defp drain(%{queue: [next | rest]} = state) do
    turn = start_turn(state, next.ref, next.message, next.timeout, nil)
    {:noreply, %{state | queue: rest, turn: turn}}
  end

  defp reply_to(nil, _result), do: :ok
  defp reply_to(from, result), do: GenServer.reply(from, result)

  # The moment a message stops being withdrawable, said out loud. A view still
  # offering to take back something the agent is already acting on is the
  # failure this exists to prevent, and it cannot know without being told.
  defp announce_delivery(%{on_event: nil}, _ref), do: :ok

  defp announce_delivery(state, ref) do
    state.on_event.(state.agent_id, %{event: :message_delivered, ref: ref})
  end

  # Short and random rather than sequential: a ref is a handle on the wire, and
  # a guessable one names another operator's message.
  defp new_ref, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  # A turn that reports itself as it goes.
  #
  # `chat/3` answers when the turn is over, which is enough to reply to whoever
  # asked and useless for watching. `stream_chat/4` takes an `on_event` and
  # calls it per step, so every step leaves here the moment it happens.
  #
  # Deliberately not the Server's PubSub: that broadcasts a result when a turn
  # *completes*, so a turn that fails broadcasts nothing and everything it did
  # first is lost. Watching exists to catch an agent going wrong, which is
  # exactly the turn that does not complete.
  defp run_turn(%{on_event: nil} = state, message, timeout) do
    # Nobody is listening, so there is nothing to stream to. Answering the
    # caller is still the job.
    Alloy.Agent.Server.chat(state.alloy, message, timeout: timeout)
  end

  defp run_turn(state, message, timeout) do
    report = state.on_event
    agent_id = state.agent_id

    Alloy.Agent.Server.stream_chat(
      state.alloy,
      message,
      # Text deltas are not reported: a step is a thing that happened — a tool
      # call, a message — and a token is not. Batching them into the channel
      # would be a lot of pushes to say one sentence.
      fn _chunk -> :ok end,
      timeout: timeout,
      on_event: fn envelope -> report.(agent_id, envelope) end
    )
  end

  defp via(agent_id), do: {:via, Registry, {@registry, {:agent, agent_id}}}

  # Liveness, not registration. The registry unregisters on a `DOWN`, so there is
  # a window after a process exits where its entry survives — and answering
  # "running" from that window is the one wrong answer this whole story is
  # about.
  defp whereis(agent_id) do
    case Registry.lookup(@registry, {:agent, agent_id}) do
      [{pid, _}] -> alive_or_gone(pid)
      [] -> {:error, :not_running}
    end
  end

  defp alive_or_gone(pid) do
    case Process.alive?(pid) do
      true -> {:ok, pid}
      false -> {:error, :not_running}
    end
  end

  # The tools run against this checkout and are told so explicitly. `Alloy`'s
  # core tools read `:working_directory` and `:allowed_paths` out of the
  # context, so scoping an agent to its copy is configuration rather than a
  # sandbox we would have to build — and `bash_restricted` stays on, because
  # Alloy is explicit that bash is a guardrail and not a sandbox. The sprite is
  # the sandbox.
  defp alloy_options(opts) do
    with {:ok, provider} <- require_opt(opts, :provider),
         {:ok, working_copy} <- require_opt(opts, :working_copy),
         credential = Keyword.get(opts, :credential, %{}),
         {:ok, provider_opts} <-
           Provider.options(provider, credential,
             model: Keyword.get(opts, :model),
             base_url: Keyword.get(opts, :base_url)
           ) do
      {:ok,
       provider_opts
       |> Keyword.put(:tools, [
         Alloy.Tool.Core.Read,
         Alloy.Tool.Core.Write,
         Alloy.Tool.Core.Edit,
         Alloy.Tool.Core.Bash
       ])
       |> Keyword.put(:working_directory, working_copy)
       |> Keyword.put(:context, %{
         working_directory: working_copy,
         allowed_paths: [working_copy],
         bash_restricted: true
       })}
    end
  end

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, :"#{key}_required"}
      value -> {:ok, value}
    end
  end

  # A checkout that is not there cannot be worked in. Named here rather than
  # discovered from a tool call failing deep in the loop, where it arrives as a
  # confusing message about a path instead of "this copy is gone".
  defp working_copy_exists(path) do
    case File.dir?(path) do
      true -> :ok
      false -> {:error, :working_copy_missing}
    end
  end
end
