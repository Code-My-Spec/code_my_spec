defmodule CmsHarness.Agents.Engine.Impl do
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

  alias Alloy.Agent.Server
  alias CmsHarness.Agents.Compaction
  alias CmsHarness.Agents.Engine.State
  alias CmsHarness.Agents.Provider
  alias CmsHarness.Agents.SystemPrompt
  alias CmsHarness.Mcp.Transport

  @registry CmsHarness.Registry
  @supervisor CmsHarness.AgentSupervisor

  # How many times round the agent loop before a turn is cut off.
  #
  # Alloy's default is 25 and nothing set it, which is fine for work that reads
  # a few files and answers, and far too small for anything driving a browser:
  # navigate, fill, click, evaluate, read is five calls to check one thing. On
  # 2026-09-07 a QA agent spent 26 calls getting a game to the state it needed
  # and was cut off before it could look at anything, twice, with two of those
  # calls lost to malformed tool arguments from the provider.
  #
  # 150 is John's number and it is a *ceiling*, not a budget: a turn that
  # finishes in four calls costs four. What it buys is that a long scenario can
  # finish inside one turn rather than being restarted from the top with its
  # context re-established every 25 calls.
  @max_turns 150

  # How long a turn may run, regardless of who sent the message.
  #
  # This used to be the *sender's* timeout, threaded from `{:send, ref, message,
  # timeout}` through `start_turn/5` into `stream_chat`. So whoever spoke to the
  # agent decided how long it was allowed to think: a four-minute HTTP client
  # made a four-minute turn, and the turn that outlived it was killed and
  # announced as the agent's own failure — `{:timeout, {GenServer, :call, …}}`
  # sitting in its transcript in its own voice, while a QA scenario it had spent
  # 165 calls on went unfinished.
  #
  # A turn's duration is a property of the turn. A caller's patience is a
  # property of the caller, and it governs how long *it* waits — `awaiting` —
  # not how long the agent works.
  #
  # Thirty minutes because a browser QA pass is minutes of real waiting: pages
  # load, LiveViews settle, and 150 steps of that is not four minutes. It is a
  # ceiling on a runaway, not a budget.
  @turn_timeout :timer.minutes(30)

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
         # Validation only. `alloy_options/1` used to start the agent's MCP
         # session as a side effect, and this call happens in *the caller's*
         # process — which for a server-pushed start is the channel. A failure
         # in there took the channel down, and with it every working copy this
         # harness serves. Sessions are opened in `init/1` now, where the agent
         # is the thing at risk.
         {:ok, _alloy_opts} <- alloy_options(opts, nil) do
      case DynamicSupervisor.start_child(@supervisor, {CmsHarness.Agents.Engine.Server, opts}) do
        {:ok, pid} ->
          Logger.info("[CmsHarness] agent #{agent_id} running in #{working_copy}")
          {:ok, %{agent_id: agent_id, pid: pid}}

        {:error, {:already_started, pid}} ->
          {:ok, %{agent_id: agent_id, pid: pid}}

        {:error, reason} ->
          Logger.warning(describe_start_failure(agent_id, working_copy, reason))
          {:error, reason}
      end
    end
  end

  @doc """
  Why a start failed, for the harness's own log.

  This branch used to log nothing at all. A failed start was therefore invisible
  here: the only record was the server's `keep_starting/2` line, which carries
  the reason as a string and nothing about where it came from.

  That cost a day. An agent stranded at `:starting` reported

      {:shutdown, {:failed_to_start_child, Anubis.Client, {:already_started, …}}}

  and the harness log had one line for the whole episode — the `terminate/2`
  that preceded it. With nothing else to go on, the module name in the reason
  was the only clue to which supervisor raised it, and the inference drawn from
  it was wrong twice (`68e535fd`).

  Names the agent and the checkout, because a harness serves fifteen of them and
  a reason with neither cannot be matched to the server's line for the same
  event.
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
  Send a message to a running agent and wait for its turn to finish.

  This is the whole of what a held stdin pipe was for.
  """
  @spec chat(String.t(), String.t(), timeout()) ::
          {:ok, term()} | {:ok, {:queued, String.t()}} | {:error, term()}
  def chat(agent_id, message, timeout \\ 180_000) do
    with {:ok, pid} <- whereis(agent_id) do
      GenServer.call(pid, {:chat, message, timeout}, timeout + call_grace_ms())
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
  The tool modules this running agent carries.

  Read off the agent rather than recomputed, so it answers about the one that
  is running rather than about what a fresh one would get.
  """
  @spec agent_tools(String.t()) :: [module()]
  def agent_tools(agent_id) do
    case whereis(agent_id) do
      {:ok, pid} -> GenServer.call(pid, :tools)
      _ -> []
    end
  end

  @doc """
  The MCP session this agent's tools call through, or nil.

  Its own, not one built beside it: a script has exactly the authority of the
  agent that ran it, and a second session would have whatever the caller gave
  it instead.
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

  Not the transcript. The server's transcript is what was *written down*, and
  an agent brought back without its history reads exactly the same on that page
  as one that has it: the rows are there either way, and the difference only
  appears when somebody asks the agent about something it was told yesterday
  and has to say it again.

  So this asks the loop. `Alloy.Agent.Server` holds the messages a turn will
  actually be run against, which is the thing "it picks up the same
  conversation" is a claim about.

  `{:error, :busy}` while a turn is running. The loop holds its own process for
  the length of a turn, and the snapshot it would answer with is the one from
  before that turn started — so waiting minutes for an answer that is already
  stale is worse than saying which of the two states this is.
  """
  @spec history(String.t()) ::
          {:ok, [Alloy.Message.t()]} | {:error, :not_running | :busy}
  def history(agent_id) do
    with {:ok, pid} <- whereis(agent_id),
         {:ok, alloy} <- GenServer.call(pid, :alloy) do
      # Asked of the loop directly rather than proxied through the engine. A
      # proxy would park the engine on a call that can take a whole turn, and an
      # agent that cannot be sent anything while somebody reads its history is
      # the failure the turn-in-a-task shape exists to avoid.
      {:ok, Server.messages(alloy)}
    end
  catch
    :exit, {:timeout, _} -> {:error, :busy}
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
    # Opened here rather than during validation, and unlinked: this process is
    # the right thing for a session's failure to reach, and nothing above it is.
    {:ok, alloy_opts} = alloy_options(opts, mcp_session(opts))

    case Server.start_link(alloy_opts) do
      {:ok, alloy} ->
        Process.flag(:trap_exit, true)

        {:ok,
         %{
           agent_id: Keyword.fetch!(opts, :agent_id),
           working_copy: Keyword.fetch!(opts, :working_copy),
           # Kept so `agent_tools/1` answers about this agent rather than
           # recomputing what a fresh one would be given.
           tools: Keyword.fetch!(alloy_opts, :tools),
           # The session the tools call through. Held so it can be asked for —
           # a spec driving `run_script` needs the same context the agent's own
           # call gets, and building a second session would be testing a
           # different one.
           mcp_client: get_in(alloy_opts, [:context, :mcp_client]),
           provider: Keyword.fetch!(opts, :provider),
           on_stop: Keyword.get(opts, :on_stop),
           on_event: Keyword.get(opts, :on_event),
           on_draft: Keyword.get(opts, :on_draft),
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

  # Asked, not killed.
  #
  # A supervisor shutdown runs this; a brutal kill does not. That difference is
  # the whole of "a stop asks the agent to finish what it is doing before it
  # insists" — anything the agent was part-way through gets to land here rather
  # than being lost with the process.
  @impl true
  def terminate(_reason, state) do
    # The session goes with the agent that opened it.
    #
    # `connect/2` unlinks the client's supervisor deliberately, so nothing here
    # took it down and a stopped agent left its client registered under a name
    # the next launch needs — which is how a restart could leave an agent worse
    # off than before it (`4078e7bf`, `dfa1ee9e`).
    #
    # The machine's browser is not this and must not be stopped here: it is
    # shared, `CmsHarness.Browser` owns it under its own name, and a second
    # agent on this machine is still using it.
    disconnect_mcp(state.mcp_client)

    run_on_stop(state.on_stop)
    Logger.info("[CmsHarness] agent #{state.agent_id} stopped")
    :ok
  end

  # `nil` on every path where the session was never opened — a machine that
  # could not authenticate gets one from `mcp_session/1`, and the agent still
  # works without it.
  defp disconnect_mcp(nil), do: :ok
  defp disconnect_mcp(client), do: Transport.impl().disconnect(client)

  defp run_on_stop(fun) when is_function(fun, 0), do: fun.()
  defp run_on_stop(_), do: :ok

  # -------------------------------------------------------------------- private

  # A turn, running where it cannot make the agent unreachable.
  #
  # In a task rather than in `handle_call` because an agent that cannot answer
  # while it works cannot be sent anything while it works — and mid-turn is
  # when an operator most wants to. Linked, and this process traps exits, so a
  # turn that crashes arrives as a message instead of taking the agent with it.
  # `_timeout` is the sender's and is deliberately unused here. It is how long
  # that caller waits, which `awaiting` settles; it is not how long the agent
  # may work. Threading it in made the two the same thing and cost a QA run.
  def start_turn(state, ref, message, _timeout, awaiting) do
    announce_delivery(state, ref)
    announce_turn_start(state)

    %{
      task: Task.async(fn -> run_turn(state, message, @turn_timeout) end),
      awaiting: awaiting,
      ref: ref
    }
  end

  # A turn ended: whoever was waiting hears about it, and whatever was waiting
  # goes next. In the order it was sent, because the second thing an operator
  # says usually assumes the first.
  def settle(state, result) do
    announce_outcome(state, result)
    reply_to(state.turn.awaiting, result)
    announce_turn_end(state, result)

    case State.finish(state) do
      {:idle, state} ->
        {:noreply, state}

      {:start, next, state} ->
        {:noreply, %{state | turn: start_turn(state, next.ref, next.message, next.timeout, nil)}}
    end
  end

  # The turn is over, said out loud.
  #
  # An external agent's turn ending fires Claude Code's Stop hook, which is
  # where the orchestrator gets to run the analyzers and decide whether the
  # agent should have stopped. This runtime fires no hooks, so nothing marked
  # the moment at all — story 1043's first rule, and the reason a turn ending
  # here enqueued no analysis and produced no decision.
  #
  # After the reply, deliberately. Whoever asked for this turn hears its answer
  # first; the decision is about what to do *next* and must not sit in front of
  # the thing that was asked for.
  #
  # Only when nothing is queued behind it — when the agent is actually done
  # rather than between two turns of one run.
  #
  # This fired on every turn end, on the reasoning that "`Analysis` supersedes a
  # duplicate rather than running it twice, so the cost of saying so early is a
  # row". The row was never the cost. In continuous mode a turn ends every
  # 15-20 seconds — the loop delivers a message, the agent acts, it settles, the
  # decision sends another — and each settle enqueued a full sweep while a spex
  # run takes ~176s. Measured on one working copy: 84 superseded against 26
  # completed.
  #
  # Superseding is not destructive (`supersede_queued/2` drops queued runs only,
  # never one in flight), so nothing was thrashing. What it cost is that the
  # decision an agent gets is built from whatever last completed, which by then
  # is several turns behind the tree it is looking at. John: "it should only run
  # the analyzer when the agent is fully done, not like between tool calls and
  # stuff."
  #
  # `queue` is the whole signal and it was already here — `drain/1` reads the
  # same field one line below to decide whether another turn starts now.
  #
  # The loop is unaffected. The message that continues it is sent *by* the
  # decision, so the queue is empty at the settle that produces it; a non-empty
  # queue means somebody already gave the agent its next thing to do, and a stop
  # decision in front of that is advice about a choice already made.
  #
  # What this gives up is the case the old comment named: a tree broken on turn
  # 3 of a long run goes unmentioned until the run ends. Accepted deliberately —
  # splitting fast analyzers from slow ones would keep both properties and is
  # more machinery than the problem is worth today.
  # A turn beginning, said out loud — the half that was missing.
  #
  # `Agents.record_turn_event/4` has always stamped `turn_started_at` from a
  # `"turn_started"` event, `WorkRepository.list_agent_work/1` reads it, and
  # `AgentWorkMapper.in_flight/1` renders it. All three were built for story
  # 1054's criteria 3297 and 3279, and the server-side comment names them. The
  # only producer was a spex fixture calling the channel directly, so the field
  # was reachable in test and unreachable in production.
  #
  # QA found it by measurement rather than by reading: a real coding agent given
  # a long generation, polled ~90 times across two runs while `message_agent`'s
  # own tracking agreed it was mid-turn, answered "in flight: nothing — no turn
  # is open" on every sample (`b48aa9e8`).
  #
  # What that costs is 3279's whole point: a long reasoning turn is supposed to
  # be distinguishable from a stalled agent, so nobody restarts it mid-flight
  # and throws away the turn and the spend. With no signal, a stall can never be
  # ruled out.
  #
  # No queue guard, unlike the end. `announce_turn_end` stays quiet while more
  # work is queued because the loop has not finished; a turn *starting* is true
  # each time one does, and a run of queued turns should read as continuously
  # busy rather than as busy once.
  defp announce_turn_start(%{on_event: nil}), do: :ok

  defp announce_turn_start(state) do
    state.on_event.(state.agent_id, %{event: :turn_started})
    :ok
  end

  defp announce_turn_end(%{on_event: nil}, _result), do: :ok

  defp announce_turn_end(%{queue: [_ | _]}, _result), do: :ok

  defp announce_turn_end(state, result) do
    state.on_event.(state.agent_id, %{event: :turn_ended, usage: usage_of(result)})
    :ok
  end

  # What the turn cost, carried on the event that says it is over.
  #
  # `Alloy.Result` accumulates `%Alloy.Usage{}` across the turn and the
  # `claude-code` provider fills it from the CLI's own `--output-format json`
  # envelope, so the numbers are the provider's rather than an estimate here.
  #
  # On the event rather than read back afterwards, because afterwards is too
  # late: `Alloy.Server.usage/1` is a call into the loop and the loop answers
  # busy while a turn is running — the same guard `history/1` has, and for the
  # same reason. An agent that claims a requirement and goes off to do it is
  # busy for minutes, so anything measuring a turn's spend by asking for it
  # got `nil` every time. Measured on story 1039's eval: 0 of 10 runs captured
  # usage, against a provider that reports it on every response.
  #
  # Nil when a turn failed before a provider answered — no spend is different
  # from zero spend, and only one of those is worth recording as a number.
  defp usage_of({:ok, %{usage: %Alloy.Usage{} = usage}}), do: Map.from_struct(usage)
  defp usage_of(%{usage: %Alloy.Usage{} = usage}), do: Map.from_struct(usage)
  defp usage_of(_result), do: nil

  # A turn that failed, said out loud.
  #
  # `chat/3` hands the error back to whoever called it, so that path is
  # covered. Nothing calls `send_message/4` and waits, on purpose — the answer
  # arrives as turn events — so on that path an error had nowhere to go, and a
  # provider refusing left the conversation quiet forever. Quiet is what an
  # agent thinking looks like, which is the one thing it must not be
  # indistinguishable from.
  defp announce_outcome(%{on_event: nil}, _result), do: :ok

  # Both shapes a failed turn arrives in, because Alloy uses both. A turn that
  # never started answers `{:error, reason}`; a turn whose provider refused
  # mid-run answers `{:ok, %Alloy.Result{status: :error}}` — an ok tuple
  # carrying a failure, which is exactly the shape that gets read as success by
  # a clause matching only the first.
  defp announce_outcome(state, {:error, reason}), do: report_failure(state, reason)

  defp announce_outcome(state, {:ok, %{status: :error, error: reason}}),
    do: report_failure(state, reason)

  # A turn that ran out of loop, said so.
  #
  # Alloy returns `{:ok, result}` with `status: :max_turns` — a successful-
  # looking tuple for a turn that was cut off — so this was indistinguishable
  # from finishing. On 2026-09-07 a QA agent spent 26 calls getting a game into
  # the state it needed, was cut at the cap, and left a transcript showing 26
  # tool calls and no reply. The only signal anyone got was a nudge about a task
  # it had never stopped working on.
  #
  # Announced before the text rather than instead of it: a cut-off turn may
  # still have said something on its way, and dropping that to report the
  # cut-off would lose the more useful half.
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

  # What the agent actually said, once it has finished saying it.
  #
  # The providers emit `:text_delta` per fragment and nothing at all when a
  # message is complete, so without this the answer exists only as tokens this
  # engine drops — and a turn that ran perfectly left a transcript holding the
  # question and no reply.
  defp announce_outcome(state, {:ok, %{text: text}}) when is_binary(text) and text != "" do
    state.on_event.(state.agent_id, %{event: :message, text: text})
  end

  # A turn that finished and said nothing.
  #
  # This fell into the catch-all below and announced nothing at all, which is
  # the failure mode this module's own comment names one clause up: "Quiet is
  # what an agent thinking looks like, which is the one thing it must not be
  # indistinguishable from." A turn that errored says so, a turn that was cut
  # off says so, and a turn that simply produced nothing was silence.
  #
  # Measured 2026-09-08 on Broken Oaths: a `claude-code` coding agent took 146
  # turns without speaking once, while a QA agent on the same machine, provider
  # and model spoke 83 times. Nothing in any log said the turns were empty —
  # they were indistinguishable from an agent choosing not to answer.
  #
  # Logged with the shape rather than the content, because the content is the
  # part that is missing. `status` separates "ran and had nothing to say" from a
  # status this function does not have a clause for, and the tool-call count
  # separates a turn that acted silently from one that did nothing at all.
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

  defp report_failure(state, reason) do
    state.on_event.(state.agent_id, %{event: :turn_failed, text: failure_text(reason)})
  end

  @doc """
  The line of a failed turn worth putting in a transcript.

  A provider's refusal is prose — several lines of it, with the whole prompt
  quoted back — so the first line is kept and the rest belongs in a log. But
  the first line is not always the one that says what went wrong: codex opens
  with its version banner, so an exhausted account read "codex exec failed with
  status 1: OpenAI Codex v0.156.1" and the `ERROR:` line naming the usage limit
  and its reset date was dropped (044599cc). When the output carries an error
  line, it is kept too, through to the next blank line.
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

  # A failed turn arrives carrying the whole run — every message, the tools,
  # the prompt. The sentence that says what went wrong is one field of it, and
  # inspecting the rest into a transcript buries it.
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

  # The moment a message stops being withdrawable, said out loud. A view still
  # offering to take back something the agent is already acting on is the
  # failure this exists to prevent, and it cannot know without being told.
  defp announce_delivery(%{on_event: nil}, _ref), do: :ok

  defp announce_delivery(state, ref) do
    state.on_event.(state.agent_id, %{event: :message_delivered, ref: ref})
  end

  # Short and random rather than sequential: a ref is a handle on the wire, and
  # a guessable one names another operator's message.
  def new_ref, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

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
    Server.chat(state.alloy, message, timeout: timeout)
  end

  defp run_turn(state, message, timeout) do
    report = state.on_event
    draft = state.on_draft
    agent_id = state.agent_id

    Server.stream_chat(
      state.alloy,
      message,
      fn _chunk -> :ok end,
      timeout: timeout,
      on_event: fn envelope -> report_step(report, draft, agent_id, envelope) end
    )
  end

  # A step is a thing that happened — a tool call, a message, a turn ending.
  # A token is not.
  #
  # Alloy emits `:text_delta` per fragment, and forwarding those puts a channel
  # push and a database row behind every few characters an agent says. Dropping
  # the `on_chunk` callback was not enough: the same fragments arrive again as
  # envelopes, which is how a sentence became forty rows in a transcript.
  #
  # `:thinking_delta` is the same fragment through the other door, and it was
  # not being dropped. A recorded turn against a real provider showed one
  # arriving; a turn with extended thinking on emits them at the same rate as
  # text, so the transcript would fill with reasoning fragments nobody asked to
  # see. Found by recording a real turn, which is what recording is for.
  #
  # Text still goes somewhere, just not here: `on_draft` carries it to the live
  # view as a draft that is never stored.
  defp report_step(_report, draft, agent_id, %{event: :text_delta} = envelope)
       when is_function(draft, 2),
       do: draft.(agent_id, envelope)

  defp report_step(_report, _draft, _agent_id, %{event: event})
       when event in [:text_delta, :thinking_delta],
       do: :ok

  defp report_step(report, _draft, agent_id, envelope), do: report.(agent_id, envelope)

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
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_running}
  end

  @doc """
  What an agent of this type carries.

  The four the loop walks, plus a handful, not ninety-eight. The rest are
  reachable through `run_script` — which is the whole of story 982: the model
  reads a few schemas per turn instead of a catalogue it has already read, and
  the ninety-odd are a lookup rather than a preamble.

  The spine is here because it has to be somewhere. `CodeMode.Catalog` excludes
  `get_next_requirement`, `sync_project`, `start_task` and `evaluate_task` from
  scripts and tells the agent "you already have them directly" — true of a
  Claude Code agent, which reaches them over MCP, and false of this one until
  they were added. An agent asked to work the graph could read about the tools
  in its own project guide and find them in no catalogue: *"it isn't available
  in the active tool catalog, despite being listed in the project guide."*

  Three more that a script may not have. `CodeMode.Catalog` excludes
  `start_agent`, `turn_off_agent` and `assign_subagent` because a loop around a
  spawn is a fleet — an argument about loops, not about an agent making one
  call. Carried here, the agent that story 963 says hands work over can actually
  hand it over; left out, it described the hand-over accurately and named a
  coordinator that was itself. See `CmsHarness.Agents.Tools.Direct`.

  Public because "what does this agent carry" is a question about a running
  agent, not about a list in this file. A constant naming five modules is true
  of the constant.
  """
  @spec tools(keyword()) :: [module()]
  def tools(_opts) do
    [
      Alloy.Tool.Core.Read,
      Alloy.Tool.Core.Write,
      Alloy.Tool.Core.Edit,
      Alloy.Tool.Core.Bash,
      CmsHarness.Agents.Tools.RunScript,
      CmsHarness.Agents.Tools.RunBrowserScript,
      CmsHarness.Agents.Tools.ToolDocs,
      # The spine. `LocalServer` mounts these four for a Claude Code agent and
      # `CodeMode.Catalog` refuses to bind them to a script — telling the agent
      # "you already have them directly", which was true over there and false
      # here until now. See `Tools.GetNextRequirement`.
      CmsHarness.Agents.Tools.GetNextRequirement,
      CmsHarness.Agents.Tools.SyncProject,
      CmsHarness.Agents.Tools.StartTask,
      CmsHarness.Agents.Tools.EvaluateTask,
      # The fourth disposition. The open-task menu offers complete, ask, tap
      # out and cancel; without this the last one named a tool the agent could
      # not call.
      CmsHarness.Agents.Tools.CancelTask,
      # The way to a person. Excluded from scripts for a reason about scripts,
      # and absent here — so every refusal that said "call `ask_user`" named a
      # tool the agent did not have. `ask_user_question` is the whole surface
      # now: `send_message` is gone, because an agent asking a person is
      # creating a durable blocker rather than sending prose.
      # Begins a sweep and returns; the result arrives as a message.
      CmsHarness.Agents.Tools.StartAnalysis,
      # The same shape, for the other long-running thing an agent starts.
      # `code_on_running_copy` is handed to the coding role, and without this
      # the agent could read about `promote` everywhere it looked and still get
      # `Unknown tool` — `ToolSets` governs Claude Code's MCP surface, this list
      # governs ours, and a tool added to one is missing from half the fleet.
      CmsHarness.Agents.Tools.Promote,
      CmsHarness.Agents.Tools.AskUserQuestion,
      # The collecting half of the two tools just above. `Validation.Menu`'s
      # offer names both of these on every refusal ("`list_user_questions`
      # shows them, `check_answer` collects a reply once one lands") and
      # neither was carried until now — the same gap `AskUserQuestion` and
      # `SendMessage` themselves closed.
      CmsHarness.Agents.Tools.ListUserQuestions,
      CmsHarness.Agents.Tools.CheckAnswer,
      # Offered on every refusal inside the loop by `Menu.tap_out_offer/1`, and
      # carried by nothing until now.
      CmsHarness.Agents.Tools.TapOut,
      # The panel beside the conversation. Excluded from scripts because a
      # script has nobody watching it; an agent does.
      CmsHarness.Agents.Tools.ShowInPanel,
      CmsHarness.Agents.Tools.StartAgent,
      CmsHarness.Agents.Tools.TurnOffAgent,
      CmsHarness.Agents.Tools.AssignSubagent
    ]
  end

  # One session per agent, started with it.
  #
  # `initialize` is a round trip, and paying it on every `run_script` would put
  # back the latency that running the script beside the data took out.
  #
  # Failure is not fatal. A machine that cannot reach the server right now
  # still has a checkout the agent can read and edit, and the two tools say so
  # when called rather than the agent refusing to exist.
  defp mcp_session(opts) do
    agent_id = Keyword.get(opts, :agent_id)
    working_copy_id = Keyword.get(opts, :working_copy_id)
    root = Keyword.get(opts, :working_copy)

    with true <- is_binary(agent_id),
         {:ok, client} <- CmsHarness.Mcp.connect(agent_id, working_copy_id, root) do
      client
    else
      other ->
        Logger.warning(
          "[CmsHarness] agent #{inspect(agent_id)} has no MCP session " <>
            "(#{inspect(other)}); it can read and edit its checkout and cannot " <>
            "reach the project's tools until it restarts"
        )

        nil
    end
  end

  @doc """
  What a direct call to a tool the engine does not carry is told.

  `reach` is the launch request's `tool_reach` (`ToolIndex.reach/1`); `nil`
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
    direct_names = Enum.map(tools(opts), & &1.name())
    &unknown_tool_message(&1, reach, direct_names)
  end

  # The tools run against this checkout and are told so explicitly. `Alloy`'s
  # core tools read `:working_directory` and `:allowed_paths` out of the
  # context, so scoping an agent to its copy is configuration rather than a
  # sandbox we would have to build — and `bash_restricted` stays on, because
  # Alloy is explicit that bash is a guardrail and not a sandbox. The sprite is
  # the sandbox.
  defp alloy_options(opts, mcp_client) do
    with {:ok, provider} <- require_opt(opts, :provider),
         {:ok, working_copy} <- require_opt(opts, :working_copy),
         credential = Keyword.get(opts, :credential, %{}),
         {:ok, provider_opts} <-
           Provider.options(provider, credential,
             model: Keyword.get(opts, :model),
             base_url: Keyword.get(opts, :base_url),
             # Machine-local, like `on_stop` and `on_event`: it is a function,
             # so it cannot cross the wire and nothing on the wire sets it.
             req_options: Keyword.get(opts, :req_options),
             # Only `claude-code` reads this today, to pin its subprocess to a
             # stable directory across the agent's calls instead of the
             # provider's own default of a fresh temp dir per call — see
             # `Provider.options/3`'s "claude-code" clause for why that
             # matters.
             working_copy: working_copy
           ) do
      {:ok,
       provider_opts
       |> Keyword.put(:tools, tools(opts))
       |> Keyword.put(:working_directory, working_copy)
       # What this agent is for, what the project is, and the loop it runs.
       # Nothing set this before, so every agent came up with
       # `system_prompt: nil` and knew only whatever message arrived next — its
       # role chose its tools and told it nothing. Issue `0f022a10`.
       #
       # Passed general to specific; `SystemPrompt` orders and joins, and every
       # piece of it was resolved by the server. `working_copy` is no longer
       # among them: the prompt used to be completed by reading the checkout's
       # own `AGENTS.md`, and a checkout without one shipped an agent that had
       # never been told to claim its work.
       |> Keyword.put(
         :system_prompt,
         SystemPrompt.compose(
           universal: Keyword.get(opts, :universal),
           project_brief: Keyword.get(opts, :project_brief),
           provider_brief: Keyword.get(opts, :provider_brief),
           app_url: Keyword.get(opts, :app_url),
           tool_index: Keyword.get(opts, :tool_index),
           role_brief: Keyword.get(opts, :role_brief)
         )
       )
       |> Keyword.put(:max_turns, @max_turns)
       |> Keyword.put(:middleware, [Compaction])
       # A code-mode tool called directly came back as a bare "Unknown tool",
       # and the main agent answered it by starting a second coder instead of
       # restarting the first.
       |> Keyword.put(:unknown_tool, unknown_tool_hook(opts))
       |> Keyword.put(:context, %{
         working_directory: working_copy,
         allowed_paths: [working_copy],
         bash_restricted: true,
         # Which agent this is, and it has to be here rather than only in
         # `Agents.tool_context/1` — that function had no production caller at
         # all, so the shape it describes was one only the specs ever built.
         #
         # Without it `Tools.RunScript` sends a script the server cannot
         # attribute, and the server reads an unattributed caller as one that
         # "could already call everything": every real agent's script reached
         # every scriptable tool whatever its row granted, while story 1038's
         # scoping criteria passed against the specs' own context. Issue
         # 33d707a2. It is also why the analyzer alert never reached a running
         # agent — `AgentAlert` appends only for a caller that named itself.
         agent_id: Keyword.fetch!(opts, :agent_id),
         # The agent's own MCP session, so a script it runs acts with exactly
         # its authority. Nil when the machine could not authenticate, which
         # the tools report rather than crashing on — an agent that can still
         # read and edit its checkout is worth more than one that refused to
         # start because the server was briefly unreachable.
         mcp_client: mcp_client,
         # How the compaction middleware reaches the agent it is running
         # inside. Middleware is a module rather than a closure, and the thing
         # it has to report to is per-agent.
         on_compaction: compaction_reporter(opts)
       })
       |> Keyword.put(:messages, resumed(Keyword.get(opts, :messages)))}
    end
  end

  # What this agent already said, and was said to it.
  #
  # `Alloy.Agent.Server` takes `:messages` at start, so resuming is starting
  # with the history it had — which is the whole reason dying with the harness
  # is an acceptable cost rather than a lost conversation. Nothing else had to
  # be built for it; the history simply had to arrive.
  #
  # Anything that is not a turn is dropped rather than guessed at. A message
  # with no role is not a user message with a default, and inventing one puts
  # words in somebody's mouth in a transcript the model will treat as fact.
  defp resumed(nil), do: []

  defp resumed(messages) when is_list(messages), do: Enum.flat_map(messages, &to_message/1)

  defp resumed(_messages), do: []

  defp to_message(%Alloy.Message{} = message), do: [message]

  defp to_message(%{"role" => "assistant", "content" => content}) when is_binary(content),
    do: [Alloy.Message.assistant(content)]

  defp to_message(%{"role" => "user", "content" => content}) when is_binary(content),
    do: [Alloy.Message.user(content)]

  # Content blocks, not just text. A seeded turn carries `tool_use` and
  # `tool_result` blocks so an agent's transcript opens having already made a
  # call of each shape — `Alloy.Message.text/1` drops them and
  # `Conversations.as_turn/1` never produced them, so without this clause they
  # arrive and are silently discarded.
  defp to_message(%{"role" => "assistant", "content" => blocks}) when is_list(blocks),
    do: [Alloy.Message.assistant_blocks(Enum.map(blocks, &atomise_block/1))]

  defp to_message(%{"role" => "user", "content" => blocks}) when is_list(blocks),
    do: [Alloy.Message.tool_results(Enum.map(blocks, &atomise_block/1))]

  defp to_message(%{role: role, content: content}),
    do: to_message(%{"role" => to_string(role), "content" => content})

  defp to_message(_other), do: []

  # Blocks cross the wire with string keys and the provider serialiser matches
  # on atoms, so a block that survived the trip would be dropped at the last
  # step instead of the first.
  defp atomise_block(block) when is_map(block) do
    Map.new(block, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> block
  end

  # A compaction, on its way to whoever keeps this agent's transcript.
  #
  # The same `on_event` every step goes through, so a checkpoint travels the
  # route that is already known to work rather than a second one beside it.
  # Nothing to report to means nothing to report — an agent nobody is keeping
  # the transcript of has nothing to resume from either.
  defp compaction_reporter(opts) do
    case {Keyword.get(opts, :on_event), Keyword.get(opts, :agent_id)} do
      {report, agent_id} when is_function(report, 2) and is_binary(agent_id) ->
        fn envelope -> report.(agent_id, envelope) end

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

  # A checkout that is not there cannot be worked in. Named here rather than
  # discovered from a tool call failing deep in the loop, where it arrives as a
  # confusing message about a path instead of "this copy is gone".
  defp working_copy_exists(path) do
    if File.dir?(path), do: :ok, else: {:error, :working_copy_missing}
  end

  # Same floor used throughout: a bit past the caller's own timeout before
  # concluding the agent is gone rather than merely still working. 5s in
  # every real environment; configurable so a test proving the timeout path
  # fires doesn't have to pay the real grace period to do it.
  defp call_grace_ms, do: Application.get_env(:code_my_spec, :call_grace_ms, 5_000)
end
