defmodule CmsHarness.Agents.Engine.Impl do
  @moduledoc """
  An agent, as a supervised process on the machine that holds its working copy.

  It consumes mailbox deliveries, stops by termination, and is alive when its
  process is. It dies with the harness; the transcript is its state, so a
  restart is a process started with the history it had. Prompts and the tool
  manifest arrive as data at start; only the loop lives here.
  See knowledge/harness, "Agent engine".
  """

  use GenServer, restart: :temporary

  require Logger

  alias Alloy.Provider.CodexSession

  alias CmsHarness.Agents.Compaction
  alias CmsHarness.Agents.Engine.Execution
  alias CmsHarness.Agents.Engine.Keeper
  alias CmsHarness.Agents.Engine.State
  alias CmsHarness.Agents.Liveness
  alias CmsHarness.Agents.Provider
  alias CmsHarness.Agents.SystemPrompt
  alias CmsHarness.Agents.ToolResults
  alias CmsHarness.Agents.Tools.Direct
  alias CmsHarness.Agents.TurnEvents
  alias CmsHarness.Agents.TurnProgress
  alias CmsHarness.Agents.UnknownTool
  alias CmsHarness.Channel
  alias CmsHarness.Copy.Supervisor, as: Copy
  alias CmsHarness.Mcp.Session

  @registry CmsHarness.Registry

  # Loop iterations before a turn is cut off. A ceiling, not a budget: Alloy's
  # default of 25 is too few for browser-driving work.
  @max_turns 150

  # Compaction budget. Alloy defaults to the model's window, 1M for Sonnet 5
  # and Opus 5.5, so an agent compacted only near a million while Claude Code
  # on the same model works within ~200k.
  @context_budget 200_000

  # Spilled tool results older than this are pruned when an agent starts. Not
  # cleared outright: the server restarts an agent with its history, and the
  # notices in it name these files.
  @spill_max_age_seconds 24 * 60 * 60

  # No wall-clock ceiling on a turn; Alloy needs a number, so this is one nobody
  # meets. A sender's timeout bounds only its own wait.
  # See knowledge/harness, "Agent engine".
  @loop_deadline :timer.hours(24)

  # Per HTTP request; otherwise Alloy hands each request the rest of the loop
  # deadline.
  @request_idle_timeout :timer.minutes(10)

  @type start_opts :: [
          agent_id: String.t(),
          provider: String.t(),
          credential: map(),
          working_copy: String.t(),
          model: String.t() | nil,
          base_url: String.t() | nil,
          messages: [map()] | nil,
          req_options: keyword() | nil,
          on_stop: (-> any()) | nil,
          on_event: (map() -> any()) | nil,
          on_draft: (String.t(), map() -> any()) | nil
        ]

  # ---------------------------------------------------------------- public API

  @doc """
  Start an agent for this request, under the harness's agent supervisor.

  Returns the agent id it is registered under and its pid. The id is
  meaningful only while this harness is running.
  """
  @spec start(start_opts()) :: {:ok, %{agent_id: String.t(), pid: pid()}} | {:error, term()}
  def start(opts) do
    with {:ok, agent_id} <- require_opt(opts, :agent_id),
         {:ok, working_copy} <- require_opt(opts, :working_copy),
         :ok <- working_copy_exists(working_copy),
         # Validation only, with no MCP session: this runs in the caller's
         # process, which may be the channel. Sessions open in `init/1`.
         {:ok, _alloy_opts} <- alloy_options(opts, nil) do
      # Under its own `Keeper`, which restarts it on a crash and gives up on a
      # crash loop. Each engine `init/1` reports an up to `Liveness`; the Keeper
      # is watched here once, so its giving up is a single final down.
      case start_keeper(working_copy, opts) do
        {:ok, keeper} ->
          Logger.info("[CmsHarness] agent #{agent_id} running in #{working_copy}")
          :ok = Liveness.watch_keeper(agent_id, keeper, working_copy)
          started(agent_id)

        {:error, {:already_started, _keeper}} ->
          started(agent_id)

        {:error, reason} ->
          Logger.warning(describe_start_failure(agent_id, working_copy, reason))
          {:error, reason}
      end
    end
  end

  # Under its copy's agents supervisor (`Copy.Supervisor`), so the copy going
  # takes its agents with it.
  defp start_keeper(working_copy, opts) do
    with {:ok, _copy} <- Copy.ensure(working_copy) do
      DynamicSupervisor.start_child(Copy.agents(working_copy), {Keeper, opts})
    end
  end

  defp started(agent_id) do
    with {:ok, pid} <- whereis(agent_id), do: {:ok, %{agent_id: agent_id, pid: pid}}
  end

  @doc """
  Why a start failed, for the harness's own log. Names the agent and the
  checkout so the line can be matched to the server's record of the same start.
  """
  @spec describe_start_failure(String.t(), String.t(), term()) :: String.t()
  def describe_start_failure(agent_id, working_copy, reason) do
    # `limit:` bounds elements, not bytes — one option list of long strings
    # still renders to kilobytes, so the rendered form is sliced as well.
    rendered =
      reason
      |> inspect(limit: 12, printable_limit: 200)
      |> String.slice(0, 500)

    "[CmsHarness] agent #{agent_id} did not start in #{working_copy}: " <> rendered
  end

  @doc """
  What this agent is doing right now.

  `busy?` reports an executing turn. Waiting payloads belong to the server mailbox.
  """
  @spec status(String.t()) ::
          {:ok, %{busy?: boolean()}} | {:error, :not_running}
  def status(agent_id) do
    with {:ok, pid} <- whereis(agent_id) do
      GenServer.call(pid, :status)
    end
  end

  @doc """
  The tool modules this running agent carries.

  Read off the running agent, not recomputed.
  """
  @spec agent_tools(String.t()) :: [module() | Alloy.Tool.Inline.t()]
  def agent_tools(agent_id) do
    case whereis(agent_id) do
      {:ok, pid} -> GenServer.call(pid, :tools)
      _ -> []
    end
  end

  @doc """
  The MCP session this agent's tools call through, or nil.

  The agent's own session, so a script has exactly the agent's authority.
  """
  @spec mcp_client(String.t()) :: pid() | nil
  def mcp_client(agent_id) do
    case whereis(agent_id) do
      {:ok, pid} -> GenServer.call(pid, :mcp_client)
      _ -> nil
    end
  end

  @doc """
  What this agent knows — every turn it is holding, oldest first.

  Not the transcript: the messages the next turn will run against. While a
  turn runs, the ones it started from.
  """
  @spec history(String.t()) :: {:ok, [Alloy.Message.t()]} | {:error, :not_running}
  def history(agent_id) do
    with {:ok, pid} <- whereis(agent_id), do: GenServer.call(pid, :history)
  end

  @doc """
  Stop one agent.

  Exactly one: never a tree, never a match by name.
  """
  @spec stop(String.t()) :: :ok | {:error, :not_running}
  def stop(agent_id) do
    case Keeper.whereis(agent_id) do
      {:ok, keeper, root} -> DynamicSupervisor.terminate_child(Copy.agents(root), keeper)
      {:error, _} = error -> error
    end
  end

  @doc """
  Agent ids this harness is running.

  Read from the registry and filtered by liveness, so it cannot disagree with
  what is alive.
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
    # The MCP session is resolved here, not during validation: this process is
    # the right thing for a session's failure to reach.
    agent_id = Keyword.fetch!(opts, :agent_id)
    # Before the options, so the tool boundary's send-now asker names it.
    generation = new_ref()
    opts = Keyword.put(opts, :generation, generation)
    {:ok, alloy_opts} = alloy_options(opts, Session.client(agent_id))
    {alloy_opts, interrupted} = restored(alloy_opts, Keeper.recall(agent_id))
    prune_spilled(spill_dir(agent_id))

    # A turn runs in a linked task; its crash arrives as a message.
    Process.flag(:trap_exit, true)
    :ok = Liveness.watch(agent_id, self(), Keyword.fetch!(opts, :working_copy))
    :ok = register_mailbox(opts, agent_id, generation)

    {:ok,
     %{
       agent_id: agent_id,
       working_copy: Keyword.fetch!(opts, :working_copy),
       # For `agent_tools/1`.
       tools: Keyword.fetch!(alloy_opts, :tools),
       # For `mcp_client/1`.
       mcp_client: get_in(alloy_opts, [:context, :mcp_client]),
       provider: Keyword.fetch!(opts, :provider),
       on_stop: Keyword.get(opts, :on_stop),
       on_event: Keyword.get(opts, :on_event),
       on_draft: Keyword.get(opts, :on_draft),
       # The history is the agent's state: each turn is `Alloy.stream/3` run
       # against it, and its result is the history the next one starts from.
       messages: Keyword.get(alloy_opts, :messages, []),
       alloy_opts: Keyword.delete(alloy_opts, :messages),
       # What the provider asked to be handed back on its next call (a CLI's
       # session to resume), carried from one turn's result to the next.
       provider_state: %{},
       # Codex's persisted thread is resumed only within one generation. A new
       # one after a turn that failed or was stopped, since that thread may
       # hold a turn Alloy's history does not; and a new one per process.
       session_generation: generation,
       # The turn in flight, or nil. One at a time — an agent working two
       # turns at once in one checkout is two agents editing one tree.
       turn: nil,
       generation: generation,
       on_consume: Keyword.get(opts, :on_consume)
     }
     |> settle_interrupted(interrupted)}
  end

  # A restart, after a crash: the history the agent had when it last wrote it
  # down (`Keeper`), not the one the server sent at its first start — that is a
  # fresh agent with a stale memory. A turn that was in flight is told to it
  # the way `recover_turn/2` tells one an abort interrupted.
  defp restored(alloy_opts, nil), do: {alloy_opts, nil}

  defp restored(alloy_opts, %{messages: messages, in_flight: nil}),
    do: {Keyword.put(alloy_opts, :messages, messages), nil}

  defp restored(alloy_opts, %{messages: messages, in_flight: message}) do
    interrupted =
      messages ++
        [
          Alloy.Message.user(message),
          Alloy.Message.user(
            "The preceding turn was interrupted: this agent's process crashed and was " <>
              "restarted. Its actions may have taken effect; inspect the current state " <>
              "before retrying."
          )
        ]

    {Keyword.put(alloy_opts, :messages, interrupted), message}
  end

  # The new generation reconciles interruption through mailbox_ready. Record
  # the checkpoint notice once; do not fabricate a completion for the old turn.
  defp settle_interrupted(state, nil), do: state

  defp settle_interrupted(state, _message) do
    :ok =
      Keeper.remember(state.agent_id, %{messages: state.messages, in_flight: nil})

    state
  end

  # A supervisor shutdown runs this (a brutal kill does not), so `on_stop` can
  # land work in progress.
  @impl true
  def terminate(reason, state) do
    # The MCP session is not closed here: it is the Keeper's child
    # (`Mcp.Session`) and closes itself when the Keeper stops it. Nor the copy's
    # browser session, which `CmsHarness.Browser.Owner` holds for the copy.
    stop_running_turn(state)
    run_on_stop(state.on_stop)
    Logger.info("[CmsHarness] agent #{state.agent_id} stopped")
    announce_death(state, reason)
    :ok
  end

  # A death for any reason but a stop is logged and put on the agent's own
  # thread; its `Keeper` restarts it.
  defp announce_death(_state, :shutdown), do: :ok
  defp announce_death(_state, {:shutdown, _}), do: :ok
  defp announce_death(%{on_event: nil}, _reason), do: :ok

  defp announce_death(state, reason) do
    text = reason |> Exception.format_exit() |> String.slice(0, 1_000)
    Logger.warning("[CmsHarness] agent #{state.agent_id} died: #{text}")
    state.on_event.(state.agent_id, %{event: :agent_died, text: text})
  end

  # A stopped agent's turn stops with it, subprocesses included. Closing a
  # port does not end the program behind it: a turned-off Claude Code agent's
  # `claude -p` kept editing its copy for ten minutes, and the loop, in a task
  # nothing linked, started another.
  defp stop_running_turn(%{turn: %{task: %Task{} = task}}) do
    case stop_turn_task(task) do
      :ok -> :ok
      {:error, failure} -> Logger.warning("[CmsHarness] stopping a turn: #{inspect(failure)}")
    end
  end

  defp stop_running_turn(_state), do: :ok

  defp run_on_stop(fun) when is_function(fun, 0), do: fun.()
  defp run_on_stop(_), do: :ok

  # -------------------------------------------------------------------- private

  defp register_mailbox(opts, agent_id, generation) do
    case Keyword.fetch!(opts, :on_register) do
      fun when is_function(fun, 2) ->
        case fun.(agent_id, generation) do
          {:ok, _} -> :ok
          :ok -> :ok
          error -> raise "Mailbox registration failed: #{inspect(error)}"
        end
    end
  end

  @doc "The server commits consumption before any model/tool execution is allowed."
  def consume_message(state, ref) do
    result =
      case state.on_consume do
        fun when is_function(fun, 3) ->
          fun.(state.agent_id, ref, state.generation)

        _ ->
          Channel.mailbox(state.working_copy, %{
            "operation" => "consume",
            "agent_id" => state.agent_id,
            "ref" => ref,
            "generation" => state.generation
          })
      end

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # A turn runs in a linked task (this process traps exits), so the agent stays
  # reachable mid-turn and a crashing turn arrives as a message. `_timeout` is
  # the sender's wait, settled via `awaiting`; it never bounds the turn.
  def start_turn(state, ref, message, _timeout, awaiting) do
    checkpoint = %{messages: state.messages}

    :ok =
      Keeper.remember(
        state.agent_id,
        %{messages: checkpoint.messages, in_flight: message, delivery_ref: ref}
      )

    announce_turn_start(state, ref)

    task = Task.async(fn -> execute(state, message) end)

    %{
      task: task,
      checkpoint: checkpoint,
      message: message,
      awaiting: awaiting,
      ref: ref,
      # The transcript at the turn's last tool boundary (`TurnProgress`), so a
      # turn stopped part-way keeps what it did. Nil until its first round.
      progress: nil
    }
  end

  # Losing the waiting task does not establish that execution stopped. An
  # abnormal waiter exit requires confirmed Alloy shutdown before a replacement
  # can consume another mailbox message.
  def abort_turn(state, reason) do
    case stop_turn_task(state.turn.task) do
      :ok ->
        recover_turn(state, reason)

      {:error, failure} ->
        {:stop, {:turn_shutdown_unconfirmed, reason, failure}, state}
    end
  end

  @doc """
  Stop the running turn so a message sent now can be the next one, keeping
  everything the turn did up to its last tool boundary.

  The agent is told it was stopped and why, and the turn ends as interrupted;
  the server delivers the message sent now next, ahead of anything queued. A
  turn stopped before its first round of tool calls keeps its prompt.
  """
  def interrupt_turn(state) do
    case stop_turn_task(state.turn.task) do
      :ok ->
        resume_interrupted(state)

      {:error, failure} ->
        {:stop, {:turn_shutdown_unconfirmed, :interrupted, failure}, state}
    end
  end

  defp resume_interrupted(state) do
    kept = state.turn.progress || started_with(state.turn)

    messages =
      kept ++
        [
          Alloy.Message.user(
            "You were stopped part-way through this turn so a message sent to you now " <>
              "could reach you; it follows. Everything you did up to your last completed " <>
              "tool call is above. A call that was running when you were stopped was cut " <>
              "off and may or may not have taken effect."
          )
        ]

    settle(stopped(state, messages), {:error, :interrupted})
  end

  # The turn task waits; the loop runs in an execution it starts unlinked, so
  # a waiter that dies leaves the execution — and the ports it owns — alive to
  # be found and stopped. A port whose owner has died is closed, and the
  # program behind it keeps running with nothing left that knows its pid.
  #
  # An execution that dies is the engine's to recover (its DOWN on this waiter
  # aborts the turn), so the waiter leaves with a shutdown reason rather than
  # crashing in `Task.await` with an error report.
  defp execute(state, message) do
    Alloy.TaskSupervisor
    |> Task.Supervisor.async_nolink(fn -> run_turn(state, message) end)
    |> Task.yield(:infinity)
    |> case do
      {:ok, result} -> result
      {:exit, reason} -> exit({:shutdown, {:execution_exited, reason}})
    end
  end

  # The waiter and everything it started — the execution, its tool tasks, a
  # CLI provider's subprocess — are found by ancestry from the waiter and
  # stopped together. The waiter is not shut down first: that would orphan
  # them before they are found.
  defp stop_turn_task(%Task{pid: pid} = task) do
    result = Execution.stop_and_release(pid)
    Task.shutdown(task, :brutal_kill)
    result
  end

  # Codex's saved thread may hold the stopped turn, which Alloy's history does
  # not, so its next call starts a new one (`:session_generation`).
  defp stopped(state, messages),
    do: %{state | messages: messages, session_generation: new_ref()}

  defp started_with(turn),
    do: turn.checkpoint.messages ++ [Alloy.Message.user(turn.message)]

  defp recover_turn(state, reason) do
    messages =
      state.turn.checkpoint.messages ++
        [
          Alloy.Message.user(state.turn.message),
          Alloy.Message.user(
            "The preceding turn was interrupted (#{inspect(reason)}). " <>
              "Its actions may have taken effect; inspect the current state before retrying."
          )
        ]

    settle(stopped(state, messages), {:error, reason})
  end

  # A turn ended: whoever was waiting hears about it, and whatever was waiting
  # goes next. In the order it was sent, because the second thing an operator
  # says usually assumes the first.
  def settle(state, result) do
    previous = state.provider_state
    state = absorb(state, result)
    :ok = Keeper.remember(state.agent_id, %{messages: state.messages, in_flight: nil})

    announce_outcome(state, result)
    reply_to(state.turn.awaiting, result)
    announce_turn_end(state, result, fresh_thread(previous, state.provider_state))

    {:idle, state} = State.finish(state)
    send(self(), :mailbox_ready)
    {:noreply, state}
  end

  # What a finished run leaves for the next turn: its history, and the provider
  # state to hand back. A failed run is treated as stopped (`stopped/2`). A
  # turn stopped by the engine arrives as a bare reason, its history already
  # set.
  defp absorb(state, {:ok, %Alloy.Result{} = result}),
    do: %{state | messages: result.messages, provider_state: provider_state(result, state)}

  defp absorb(state, {:error, %Alloy.Result{} = result}),
    do: %{stopped(state, result.messages) | provider_state: provider_state(result, state)}

  defp absorb(state, _result), do: state

  defp provider_state(result, state),
    do: Map.get(result.metadata, :provider_state, state.provider_state)

  # Every completed turn reports its ref and generation. The server decides
  # whether durable waiting work or the stop decision goes next. A separate
  # ready event after settling closes the race with a dispatch that saw busy.
  defp announce_turn_start(%{on_event: nil}, _ref), do: :ok

  defp announce_turn_start(state, ref) do
    state.on_event.(state.agent_id, %{
      event: :turn_started,
      ref: ref,
      generation: state.generation
    })

    :ok
  end

  defp announce_turn_end(%{on_event: nil}, _result, _fresh), do: :ok

  defp announce_turn_end(state, result, fresh) do
    state.on_event.(state.agent_id, %{
      event: :turn_ended,
      usage: with_fresh_thread(usage_of(result), fresh),
      ref: state.turn && state.turn.ref,
      generation: state.generation
    })

    :ok
  end

  @doc """
  Why this turn started a new Codex thread partway through the conversation
  (sending the whole transcript uncached), from the provider state before and
  after it; nil when it did not. Carried with the turn's usage, so the token
  alert and check-in can say so.
  """
  @spec fresh_thread(map() | nil, map() | nil) :: String.t() | nil
  def fresh_thread(previous, current) do
    {before, _reason} = CodexSession.fresh_threads(previous)

    case CodexSession.fresh_threads(current) do
      {count, reason} when count > before -> reason
      _ -> nil
    end
  end

  defp with_fresh_thread(usage, nil), do: usage
  defp with_fresh_thread(nil, reason), do: %{fresh_thread: reason}
  defp with_fresh_thread(usage, reason), do: Map.put(usage, :fresh_thread, reason)

  # The provider's own usage, carried on `turn_ended`: asking the loop
  # afterwards answers busy while the next turn runs. Nil (not zero) when no
  # provider answered.
  defp usage_of({_ok_or_error, %{usage: %Alloy.Usage{} = usage}}), do: Map.from_struct(usage)
  defp usage_of(%{usage: %Alloy.Usage{} = usage}), do: Map.from_struct(usage)
  defp usage_of(_result), do: nil

  # Every outcome is announced as a turn event; most callers do not wait for
  # the reply, and silence reads as an agent thinking.
  defp announce_outcome(%{on_event: nil}, _result), do: :ok

  # A failure arrives as `{:error, reason}` or as `{:ok, %{status: :error}}`.
  # An interrupt is not a failure: reporting one would re-offer the turn and
  # flag the agent stalled.
  defp announce_outcome(_state, {:error, :interrupted}), do: :ok
  defp announce_outcome(state, {:error, reason}), do: report_failure(state, reason)

  defp announce_outcome(state, {:ok, %{status: :error, error: reason}}),
    do: report_failure(state, reason)

  # `status: :max_turns` arrives as an `:ok` tuple; say it was cut off, after
  # any text it produced.
  defp announce_outcome(state, {:ok, %{status: :max_turns} = result}) do
    if is_binary(result.text) and result.text != "" do
      state.on_event.(state.agent_id, %{event: :message, text: result.text})
    end

    state.on_event.(state.agent_id, %{
      event: :turn_cut_off,
      text:
        "This turn hit the #{@max_turns}-step limit and was cut off — you did not " <>
          "finish, and nothing about the work is wrong. Pick up where you left " <>
          "off. If a single turn keeps running out here, say so rather than " <>
          "starting the same approach again."
    })
  end

  # The completed message: providers emit only per-fragment deltas, which
  # `report_step/4` drops. A tool call leaked as DSML text (DeepSeek) ran
  # nothing, so that turn is also reported as failed.
  @leaked_tool_call "your tool call came back as text (<｜DSML｜ …>) and did not run; make it again as a real tool call"

  defp announce_outcome(state, {:ok, %{text: text}}) when is_binary(text) and text != "" do
    state.on_event.(state.agent_id, %{event: :message, text: text})
    if leaked_tool_call?(text), do: report_failure(state, @leaked_tool_call)
  end

  # A turn that finished and said nothing: logged with its shape (status,
  # message count, keys), since the content is what is missing.
  defp announce_outcome(state, {:ok, result}) do
    require Logger

    Logger.warning(
      "[CmsHarness] agent #{state.agent_id} finished a turn with nothing to say: " <>
        "status=#{inspect(Map.get(result, :status))} " <>
        "text=#{inspect(Map.get(result, :text))} " <>
        "messages=#{length(List.wrap(Map.get(result, :messages)))} " <>
        "keys=#{inspect(result |> Map.from_struct() |> Map.keys())}"
    )

    :ok
  rescue
    # `result` is not always a struct, and a diagnostic must not be able to end
    # a turn that otherwise succeeded.
    _ -> :ok
  end

  defp announce_outcome(_state, _result), do: :ok

  defp leaked_tool_call?(text), do: String.contains?(text, "｜DSML｜")

  defp report_failure(state, reason) do
    state.on_event.(state.agent_id, %{event: :turn_failed, text: failure_text(reason)})
  end

  @doc """
  The line of a failed turn worth putting in a transcript.

  The first line, plus the paragraph starting at the first `error` line if
  there is one (codex opens with a version banner). Capped at 500 characters.
  """
  @spec failure_text(term()) :: String.t()
  def failure_text(reason) when is_binary(reason) do
    [headline | rest] = String.split(reason, "\n")

    case error_paragraph(rest) do
      nil -> headline
      error -> headline <> " — " <> error
    end
    |> String.slice(0, 500)
  end

  # A failed result carries the whole run; only its `error` field is wanted.
  def failure_text(%{error: reason}) when reason != nil, do: failure_text(reason)

  def failure_text(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp error_paragraph(lines) do
    case Enum.drop_while(lines, &(not Regex.match?(~r/^\s*error\b/i, &1))) do
      [] ->
        nil

      paragraph ->
        paragraph
        |> Enum.take_while(&(String.trim(&1) != ""))
        |> Enum.map_join(" ", &String.trim/1)
    end
  end

  defp reply_to(nil, _result), do: :ok
  defp reply_to(from, result), do: GenServer.reply(from, result)

  # Short and random rather than sequential: a ref is a handle on the wire, and
  # a guessable one names another operator's message.
  def new_ref, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  # One turn: the loop run against the history the agent holds. `on_event`
  # reports each step as it happens; text arrives as `:text_delta` envelopes
  # there too, so the chunk callback has nothing to do. The loop's own
  # `timeout_ms` bounds it.
  defp run_turn(%{on_event: nil} = state, message) do
    # Nobody is listening; just answer the caller.
    Alloy.run(message, turn_options(state))
  end

  defp run_turn(state, message) do
    report = state.on_event
    draft = state.on_draft
    agent_id = state.agent_id

    Alloy.stream(
      message,
      fn _chunk -> :ok end,
      Keyword.put(turn_options(state), :on_event, fn envelope ->
        report_step(report, draft, agent_id, envelope)
      end)
    )
  end

  defp turn_options(state) do
    state.alloy_opts
    |> Keyword.put(:messages, state.messages)
    |> Keyword.update!(:provider, fn {module, config} ->
      {module, provider_config(module, config, state)}
    end)
  end

  defp provider_config(Alloy.Provider.Codex, config, state) do
    config
    |> Map.put(:provider_state, state.provider_state)
    |> Map.put(:session_generation, state.session_generation)
  end

  defp provider_config(_module, config, state),
    do: Map.put(config, :provider_state, state.provider_state)

  # A step is a tool call, a message, a turn ending — not a token.
  # `:text_delta` and `:thinking_delta` are never reported as steps (each would
  # be a channel push and a transcript row); text deltas go to `on_draft`, a
  # live draft that is never stored.
  defp report_step(_report, draft, agent_id, %{event: :text_delta} = envelope)
       when is_function(draft, 2),
       do: draft.(agent_id, envelope)

  defp report_step(_report, _draft, _agent_id, %{event: event})
       when event in [:text_delta, :thinking_delta],
       do: :ok

  defp report_step(report, _draft, agent_id, envelope),
    do: report.(agent_id, TurnEvents.with_result(envelope))

  defp via(agent_id), do: {:via, Registry, {@registry, {:agent, agent_id}}}

  # Liveness, not registration: an entry survives briefly after its process
  # exits, until the registry handles the `DOWN`.
  defp whereis(agent_id) do
    case Registry.lookup(@registry, {:agent, agent_id}) do
      [{pid, _}] -> alive_or_gone(pid)
      [] -> {:error, :not_running}
    end
  end

  defp alive_or_gone(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_running}
  end

  @doc """
  What an agent of this type carries.

  The four core tools (read, write, edit, bash) plus the launch request's
  `direct_tools`: the server's `ToolIndex.carried_definitions/1`, each built by
  `direct_tool/1`. Everything else is reached through `run_script`. Tools
  `CodeMode.Catalog` excludes from scripts must be direct here. See
  knowledge/harness, "Agent engine".
  """
  @spec tools(keyword()) :: [module() | Alloy.Tool.Inline.t()]
  def tools(opts) do
    [
      CmsHarness.Agents.Tools.Read,
      Alloy.Tool.Core.Write,
      Alloy.Tool.Core.Edit,
      CmsHarness.Agents.Tools.Bash
    ] ++
      Enum.map(Keyword.get(opts, :direct_tools) || [], &direct_tool/1)
  end

  @doc """
  One carried tool. A harness module of the tool's name when it does more
  than forward (`run_script`, `run_browser_script`, `tool_docs`); otherwise a
  forward to the server built from the definition.
  """
  @spec direct_tool(map()) :: module() | Alloy.Tool.Inline.t()
  def direct_tool(%{"name" => name} = definition) do
    module = Module.concat(CmsHarness.Agents.Tools, Macro.camelize(name))

    if Code.ensure_loaded?(module) and function_exported?(module, :execute, 2),
      do: module,
      else: Direct.tool(definition)
  end

  @doc "A tool's name, whether it is a module or an inline tool."
  @spec tool_name(module() | Alloy.Tool.Inline.t()) :: String.t()
  def tool_name(%Alloy.Tool.Inline{name: name}), do: name
  def tool_name(module) when is_atom(module), do: module.name()

  @doc """
  What a direct call to a tool the engine does not carry is told.

  `reach` is the launch request's `tool_reach` (`ToolIndex.reach/2`); `nil`
  from an older server keeps the run_script hint. `direct_names` are the
  engine's own tools.
  """
  @spec unknown_tool_message(String.t(), map() | nil, [String.t()]) :: String.t()
  def unknown_tool_message(name, nil, _direct_names), do: run_script_hint(name)

  # Exact names before the fuzzy match, so a real ungranted tool is never
  # mistaken for a typo of a direct one.
  def unknown_tool_message(name, reach, direct_names) when is_map(reach) do
    cond do
      name in Map.get(reach, "scriptable", []) ->
        run_script_hint(name)

      name in Map.get(reach, "not_granted", []) ->
        "Your role does not have `#{name}`, directly or through run_script, so do " <>
          "not try run_script. #{held_by(reach, name)}"

      match = closest(name, direct_names) ->
        "`#{name}` is not a tool. Did you mean `#{match}`? It is called directly."

      true ->
        "No tool named `#{name}` exists. tool_docs lists the ones you can reach."
    end
  end

  defp run_script_hint(name),
    do: "`#{name}` is not a direct tool; call it from run_script (tool_docs lists them)"

  defp closest(name, direct_names) do
    down = String.downcase(name)

    direct_names
    |> Enum.map(&{&1, String.jaro_distance(down, String.downcase(&1))})
    |> Enum.filter(fn {_candidate, score} -> score >= 0.85 end)
    |> Enum.max_by(fn {_candidate, score} -> score end, fn -> nil end)
    |> case do
      {candidate, _score} -> candidate
      nil -> nil
    end
  end

  defp held_by(reach, name) do
    case get_in(reach, ["holders", name]) do
      [_ | _] = roles -> "Roles that carry it: #{Enum.join(roles, ", ")}."
      _ -> ""
    end
    |> String.trim()
  end

  defp unknown_tool_hook(opts) do
    reach = Keyword.get(opts, :tool_reach)
    direct_names = Enum.map(tools(opts), &tool_name/1)
    &unknown_tool_message(&1, reach, direct_names)
  end

  # Scoped to the checkout by `:working_directory` and `:allowed_paths`;
  # `bash_restricted` is a guardrail, not a sandbox (the sprite is the sandbox).
  defp alloy_options(opts, mcp_client) do
    with {:ok, provider} <- require_opt(opts, :provider),
         {:ok, working_copy} <- require_opt(opts, :working_copy),
         credential = Keyword.get(opts, :credential, %{}),
         {:ok, provider_opts} <-
           Provider.options(provider, credential,
             model: Keyword.get(opts, :model),
             base_url: Keyword.get(opts, :base_url),
             provider_brief: Keyword.get(opts, :provider_brief),
             # Machine-local; nothing on the wire sets it.
             req_options:
               Keyword.put_new(
                 Keyword.get(opts, :req_options) || [],
                 :receive_timeout,
                 @request_idle_timeout
               ),
             # The subprocess providers (`claude-code`, `openai-codex`) run
             # in it instead of their default of a fresh temp dir per call.
             working_copy: working_copy
           ) do
      {:ok,
       provider_opts
       |> Keyword.put(:tools, tools(opts))
       |> Keyword.put(:working_directory, working_copy)
       # Every piece resolved by the server; `SystemPrompt` orders and joins
       # them general to specific. Nothing is read from the checkout.
       |> Keyword.put(
         :system_prompt,
         SystemPrompt.compose(
           universal: Keyword.get(opts, :universal),
           provider_brief: Keyword.get(opts, :provider_brief),
           app_url: Keyword.get(opts, :app_url),
           scratch_dir: scratch_dir(Keyword.fetch!(opts, :agent_id)),
           tool_index: Keyword.get(opts, :tool_index),
           role_brief: Keyword.get(opts, :role_brief)
         )
       )
       |> Keyword.put(:max_turns, @max_turns)
       |> Keyword.put(:max_tokens, @context_budget)
       # Alloy bounds the whole loop by this (its default is two minutes).
       |> Keyword.put(:timeout_ms, @loop_deadline)
       # Bash owns its explicit deadline (up to one hour), including process
       # cleanup. The executor's default two minutes must not kill an install
       # before Bash can enforce that deadline and report partial output.
       |> Keyword.put(:tool_timeout, :timer.hours(1) + 5_000)
       # `ToolResults`: an error struct in a result block cannot be JSON-encoded
       # for the next request. `UnknownTool`: where an uncarried tool is
       # reachable. `TurnProgress`: an interrupted turn keeps what it did.
       # `TurnEvents` last, so the result it reports is the one the model sees.
       |> Keyword.put(:middleware, [
         Compaction,
         ToolResults,
         UnknownTool,
         TurnProgress,
         TurnEvents
       ])
       |> Keyword.put(:context, %{
         working_directory: working_copy,
         allowed_paths: [
           working_copy,
           spill_dir(Keyword.fetch!(opts, :agent_id)),
           scratch_dir(Keyword.fetch!(opts, :agent_id))
         ],
         bash_restricted: true,
         # Required: the server scopes a script's tools (and appends agent
         # alerts) only for a caller that names itself.
         agent_id: Keyword.fetch!(opts, :agent_id),
         # The copy whose harness runs its `mix test` (`Tools.Bash`).
         working_copy_id: Keyword.get(opts, :working_copy_id),
         # The agent's own MCP session. Nil when the machine could not
         # authenticate; the tools report that rather than crash.
         mcp_client: mcp_client,
         # Middleware is a module, so its per-agent reporter rides the context.
         on_compaction: compaction_reporter(opts),
         on_turn_event: compaction_reporter(opts),
         # Read by `UnknownTool`.
         unknown_tool: unknown_tool_hook(opts),
         # Long results spill here (`Spill`, in the tools), outside the
         # checkout so the tree stays clean.
         spill_dir: spill_dir(Keyword.fetch!(opts, :agent_id)),
         # Told after each round of tool calls what the turn has done so far.
         on_progress: progress_reporter(opts)
       })
       |> Keyword.put(:messages, resumed(Keyword.get(opts, :messages)))}
    end
  end

  @doc "Where an agent's tool results too long to deliver are saved."
  @spec spill_dir(String.t()) :: String.t()
  def spill_dir(agent_id),
    do: Path.join([CmsHarness.Config.local_state_dir(), "agent_output", agent_id])

  @doc """
  Where an agent's own disposable fixtures -- a mock server, its log, anything
  a QA run builds through `bash` to test against -- may be written and read
  back.

  QA built fixtures like this under an ad hoc `mktemp` path, which
  `bash` (a guardrail, not a sandbox) can always write to, but the read tool
  refused -- outside `working_copy` and `spill_dir`, the only paths `Alloy`'s
  own tools allow. This path is advertised instead (`RoleBrief`'s QA entry),
  so a fixture built here is one the same agent can read back.
  """
  @spec scratch_dir(String.t()) :: String.t()
  def scratch_dir(agent_id),
    do: Path.join([CmsHarness.Config.local_state_dir(), "agent_scratch", agent_id])

  defp prune_spilled(dir) do
    cutoff = System.os_time(:second) - @spill_max_age_seconds

    for name <- ls(dir),
        path = Path.join(dir, name),
        match?({:ok, %{mtime: mtime}} when mtime < cutoff, File.stat(path, time: :posix)) do
      File.rm(path)
    end

    :ok
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  # The history to resume with. Anything that is not a turn is dropped, never
  # given a default role.
  defp resumed(nil), do: []

  defp resumed(messages) when is_list(messages), do: Enum.flat_map(messages, &to_message/1)

  defp resumed(_messages), do: []

  defp to_message(%Alloy.Message{} = message), do: [message]

  defp to_message(%{"role" => "assistant", "content" => content}) when is_binary(content),
    do: [Alloy.Message.assistant(content)]

  defp to_message(%{"role" => "user", "content" => content}) when is_binary(content),
    do: [Alloy.Message.user(content)]

  # Content blocks (`tool_use`, `tool_result`), not just text.
  defp to_message(%{"role" => "assistant", "content" => blocks}) when is_list(blocks),
    do: [Alloy.Message.assistant_blocks(Enum.map(blocks, &atomise_block/1))]

  defp to_message(%{"role" => "user", "content" => blocks}) when is_list(blocks),
    do: [Alloy.Message.tool_results(Enum.map(blocks, &atomise_block/1))]

  defp to_message(%{role: role, content: content}),
    do: to_message(%{"role" => to_string(role), "content" => content})

  defp to_message(_other), do: []

  # Blocks cross the wire with string keys; the provider serialiser matches
  # atoms.
  defp atomise_block(block) when is_map(block) do
    Map.new(block, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> block
  end

  # Compactions travel the same `on_event` route as steps; nil without one.
  defp compaction_reporter(opts) do
    case {Keyword.get(opts, :on_event), Keyword.get(opts, :agent_id)} do
      {report, agent_id} when is_function(report, 2) and is_binary(agent_id) ->
        fn envelope -> report.(agent_id, envelope) end

      _ ->
        nil
    end
  end

  # Nil until the engine has minted its generation: validation builds these
  # options too, and there is no turn to report on. Built in the engine's
  # `init/1`, so `self()` is the engine; the middleware runs in the Alloy
  # process and sends to it.
  defp progress_reporter(opts) do
    case Keyword.get(opts, :generation) do
      generation when is_binary(generation) ->
        engine = self()
        fn messages -> send(engine, {:turn_progress, messages}) end

      _ ->
        nil
    end
  end

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, :"#{key}_required"}
      value -> {:ok, value}
    end
  end

  # Fail the start, rather than a tool call deep in the loop.
  defp working_copy_exists(path) do
    if File.dir?(path), do: :ok, else: {:error, :working_copy_missing}
  end
end
