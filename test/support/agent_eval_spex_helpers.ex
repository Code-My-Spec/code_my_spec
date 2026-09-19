defmodule CodeMySpecSpex.AgentEvalHelpers do
  @moduledoc """
  Story 1070's shared premise: a fresh agent, a real model, and a record of
  what it called.

  Every other spex in this suite drives a surface and asserts on the answer.
  These drive an *agent* and assert on its conduct, so three things differ and
  all three are here rather than in each criterion.

  ## The agent is the user

  There is no stand-in. The agent is started through `start_agent`, the tool an
  operator starts one with, so its system prompt is `RoleBrief.for/1`'s, its
  tool list is `ToolIndex`'s, and its turn runs Alloy's real loop against the
  real tools. A scripted provider would assert on the script.

  `claude-code` is the provider because it is the one that costs nothing per
  run and really emits tool calls. `CmsHarnessTest.HeldProvider` cannot: it
  returns one canned answer and no `tool_use` blocks, which is what left
  criterion 2886 unwritten.

  ## What it called, not what it said

  Assertions read `read_agent_conversation`, the main agent's own tool. A model
  will happily narrate a call it never made, so "it says it called
  `start_task`" and "it called `start_task`" are different claims and only the
  second one is worth anything. The transcript reaches the server over a real
  channel — see `CodeMySpecTest.TurnEventRelay` for the hop that makes that
  true in a spex.

  ## A rate, not a pass

  The model is non-deterministic, so one run says almost nothing. `measure/3`
  runs a scenario repeatedly with a fresh agent each time and `assert_rate/2`
  judges the proportion against the criterion's own threshold.

  A rate in between is the finding, not a nuisance: an agent that does the
  right thing six times in ten has an ambiguous prompt, and that is information
  no single-run test can produce. `assert_rate/2` says so in those words rather
  than suggesting a retry.
  """

  import ExUnit.Assertions
  import Phoenix.ChannelTest, only: [subscribe_and_join: 4]

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  @doc """
  How many times a behavioural criterion is measured.

  Ten by default, which is what the criteria state their thresholds against.
  Lower it while writing one — `config :code_my_spec, :agent_eval_runs, 2` — and
  note that a threshold asserted over two runs is a smoke test rather than a
  measurement.
  """
  @spec runs() :: pos_integer()
  def runs, do: Application.get_env(:code_my_spec, :agent_eval_runs, 10)

  @doc """
  Bring a checkout onto the harness and send its agents' turns to the server.

  Answers the context with `:copy` and `:harness_socket`. Both are needed for a
  transcript to exist at all: the agent runs against the checkout, and the
  socket is where its turn events land.
  """
  @spec given_a_harnessed_checkout(map(), String.t()) :: map()
  def given_a_harnessed_checkout(context, label) do
    copy = CodeMySpec.TempFile.dir(label)
    File.mkdir_p!(copy)

    # `harness_id` is nil because this checkout has never described itself
    # before — the join is what mints it. Naming one would name a copy that
    # reported a different tree, and the graph these agents work from would
    # then be somebody else's.
    {:ok, reply, socket} =
      UserSocket
      |> Phoenix.ChannelTest.socket("eval-#{label}", %{scope: context.scope})
      |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
        "contract_version" => HarnessProjectChannel.contract_version(),
        "harness_id" => nil,
        "root" => copy,
        "label" => "the machine these agents run on",
        # A checkout is {project, device, root}, so a join that names no machine
        # is refused — two boxes share a path constantly.
        "device" => %{"id" => Fixtures.device_fixture(context.scope).id}
      })

    Fixtures.relay_turn_events(socket)

    # Whose authority these agents' tool calls run with. In production the
    # transport carries `x-harness-id` and the server resolves the scope from
    # it; in this VM the local transport reads it from application env, the way
    # `AgentToolsHelpers` does.
    #
    # At this checkout's vantage rather than the test's, because an agent's
    # graph is computed from its own copy's files — the blended vantage reads a
    # file present in any checkout as present, which `Preloader.load/1` calls a
    # bug on an agent path in as many words.
    at_this_copy = %{context.scope | active_working_copy_id: reply.working_copy_id}
    scope_agents_at(at_this_copy)
    warm_the_graph(at_this_copy)

    context
    |> Map.put(:copy, copy)
    |> Map.put(:copy_id, reply.working_copy_id)
    |> Map.put(:harness_socket, socket)
  end

  # Compute this checkout's graph before anything is woken against it.
  #
  # A wake renders the role's menu from the requirements read model and stays
  # silent for a role whose menu is empty — deliberately, so an idle agent costs
  # nothing. A checkout that has just joined has no rows yet, so the first wake
  # after a join can be sent into a graph that has not been computed and the
  # agent is never given a turn at all.
  #
  # `Agents.wake_roles/3` names the same window: "a role whose work became
  # actionable in the same breath as this completion may therefore not show
  # until something recomputes. That is a nudge arriving late rather than a wake
  # being lost." Late is fine for an agent that will be woken again; it is not
  # fine for a measured run, which gets exactly one.
  #
  # Measured 2026-09-17: over three runs of criterion 3539, run 1 read "called
  # nothing at all" and runs 2 and 3 were clean — the first paying for the cold
  # graph and the rest inheriting a warm one.
  defp warm_the_graph(scope) do
    Fixtures.watch_graph(scope)
    Fixtures.settle_graph(scope)
    :ok
  end

  defp scope_agents_at(scope) do
    prior = Application.get_env(:code_my_spec, :harness_mcp_scope)
    Application.put_env(:code_my_spec, :harness_mcp_scope, scope)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:code_my_spec, :harness_mcp_scope)
        scope -> Application.put_env(:code_my_spec, :harness_mcp_scope, scope)
      end
    end)
  end

  @doc """
  A new agent of `role`, started the way an operator starts one.

  Fresh every call, and that is the point: a long-lived agent's conduct tells
  you about its own accumulated history — a day of stale questions, a
  stand-down later reversed — rather than about the prompt and tools, which is
  what these criteria are about.

  Answers the agent id. Stopping it is the caller's business; `stop/2` does it
  and every measured run should, or ten runs leave ten agents on the machine —
  and the second run is already refused for it.
  """
  @spec fresh_agent(map(), String.t()) :: String.t()
  def fresh_agent(context, role \\ "coding") do
    {:reply, response, _} =
      StartAgent.execute(
        %{
          role: role,
          provider: "claude-code",
          working_copy: context.copy,
          working_copy_id: context.copy_id
        },
        frame(context)
      )

    refute response.isError,
           """
           No agent was started, so this run measures nothing.

           #{text(response)}
           """

    agent_id_in(text(response)) ||
      flunk("""
      An agent was started and the answer does not name it, so there is nothing
      to ask what it did.

      #{text(response)}
      """)
  end

  @doc """
  Stop one, whatever state it reached, through the tool an operator stops with.

  `CmsHarness.Agents.halt/1` was the obvious call and is only half of it: it
  ends the process and leaves the server's row saying `running`. Ten runs then
  leave ten agents the project believes are alive — which the second run
  already trips over, because `Agents.start_agent/2` refuses a second agent on
  the project's main checkout and `main_agent/1` counts *any* running row
  there.

  Measured 2026-09-17: `--runs 1` green, `--runs 10` refused on run 2 with
  "Something is already running in this project's main checkout". The refusal
  was correct and the leak was mine.

  `StopAgent` is what a person stops with, so what the next run starts against
  is the state a real stop leaves behind.
  """
  @spec stop(map(), String.t()) :: :ok
  def stop(context, agent_id) do
    {:reply, _response, _} = StopAgent.execute(%{agent_id: agent_id}, frame(context))
    :ok
  end

  @doc """
  One measured run: a fresh agent, a turn, and a verdict on what it called.

  `fun` takes the agent's id and answers whether it did the named thing.
  Answers `{held?, evidence}` for `measure/2`, with the evidence being every
  tool it called in order — which is what makes a rate of zero actionable
  instead of merely disappointing.

  The agent is stopped whichever way the run goes, because ten runs that each
  leave a `claude` subprocess behind is a machine nobody can work on. The
  `try` lives here rather than in the criterion for the reason the framework
  check states: a spex body with imperative `try` in it is pinning setup it
  should be asserting on.

  ## Options

    * `:role` — which role's brief and tool set. `"coding"` by default.
    * `:say` — a message to send after waking, for a criterion whose premise is
      being told something rather than finding work on the graph. It goes
      through `message_agent`, which is what an operator's message goes
      through.
    * `:wake` — `false` for a criterion whose premise is an agent that was
      never put in the loop.
  """
  @spec observe(map(), keyword(), (String.t() -> boolean())) :: {boolean(), String.t()}
  def observe(context, opts \\ [], fun) do
    agent_id = fresh_agent(context, Keyword.get(opts, :role, "coding"))

    try do
      if Keyword.get(opts, :wake, true), do: wake(context, agent_id)
      if said = Keyword.get(opts, :say), do: say(agent_id, said)
      settle(agent_id)

      {fun.(agent_id), transcript_of(context, agent_id)}
    after
      stop(context, agent_id)
    end
  end

  @doc """
  Tell a running agent something, the way an operator's message reaches it.

  Without waiting: what is being measured is what the agent *does* with it, and
  `settle/1` is what says the turn is over.
  """
  @spec say(String.t(), String.t()) :: :ok
  def say(agent_id, text) do
    # Asserted rather than discarded. `send_message/4` answers `:started`,
    # `:queued` or an error, and this threw the answer away — so a delivery
    # that never happened produced a run where the agent said nothing, counted
    # as a miss, and read as the agent declining to act.
    #
    # Measured 2026-09-17: criterion 3543 reported 0 of 3 with "called nothing
    # at all" three times, in 28 seconds — three agents that were never spoken
    # to at all. A rate built out of undelivered messages is a statement about
    # the helper wearing the costume of a statement about the agent, which is
    # the one thing these criteria must not produce.
    case Fixtures.message_agent_and_wait(agent_id, text, settle_timeout()) do
      {:ok, said} ->
        dump(agent_id <> " replied", said)
        :ok

      other ->
        flunk("""
        The agent was never told anything, so this run measures nothing about
        what it does when told.

        Sending to #{agent_id} answered: #{inspect(other)}
        """)
    end
  end

  @doc """
  Put the agent in the loop, which is what makes it take a turn.

  The production trigger, and the whole of it: an agent is a supervised process
  that acts when messaged and nothing polls, so `set_agent_continuous` sets the
  flag and rings the bell. The menu it wakes with is `StopDecision.wake/2`'s —
  rendered from the graph, addressed to this role — which is the same first
  turn a real agent gets.
  """
  @spec wake(map(), String.t()) :: String.t()
  def wake(context, agent_id) do
    {:reply, response, _} =
      SetAgentContinuous.execute(%{agent_id: agent_id, continuous: true}, frame(context))

    said = text(response)

    refute response.isError,
           """
           The agent could not be put in the loop, so it never took a turn and
           this run measures nothing about its conduct.

           #{said}
           """

    said
  end

  @doc """
  Wait until the agent has nothing in flight and nothing queued.

  What makes a claim about a turn settleable. A turn still running and a turn
  that went nowhere look identical from outside, so an assertion made a moment
  early is true of both.

  Minutes rather than `await_idle/1`'s five seconds. A real turn is a `claude`
  subprocess and however many tool round trips the model decides to make, and a
  deadline that expires part-way through does not record a miss — it throws
  away the run.
  """
  @spec settle(String.t()) :: :ok
  def settle(agent_id), do: CmsHarnessTest.Machine.await_idle(agent_id, settle_timeout())

  @doc """
  How long one measured turn may take before the run is abandoned.

  `config :code_my_spec, :agent_eval_settle_timeout`. Five minutes by default,
  which is a multi-turn tool loop against `claude -p` with room to spare.
  """
  @spec settle_timeout() :: timeout()
  def settle_timeout, do: Application.get_env(:code_my_spec, :agent_eval_settle_timeout, 300_000)

  @doc """
  How long a whole measured criterion may take, as a `@moduletag timeout:`.

  `CodeMySpecSpex.Case` sets three minutes, which is right for a spex that
  drives a surface and far too short for one that drives ten agents — measured
  2026-09-17, where every behavioural criterion died at exactly 180000ms with
  its `claude` subprocess orphaned and every completed run in that measurement
  thrown away.

  Derived from the run count rather than picked, so lowering `--runs` lowers
  this too and a wedged run still fails rather than hanging forever.
  """
  @spec eval_timeout() :: timeout()
  def eval_timeout, do: runs() * settle_timeout() + 120_000

  @doc """
  Every tool this agent called, oldest first, by name.

  Through `read_agent_conversation` rather than Alloy's own history: the
  question is what the agent did, and asking the agent is the one source that
  cannot distinguish a call from a claim about a call.
  """
  @spec tools_called(map(), String.t()) :: [String.t()]
  def tools_called(context, agent_id), do: context |> conversation(agent_id) |> tool_names()

  @doc """
  The agent's conversation, rendered as the main agent reads it.

  The raw form, for the criteria whose claim is about something inside a call
  rather than about which call it was — a script's text, most often.
  """
  @spec conversation(map(), String.t()) :: String.t()
  def conversation(context, agent_id) do
    {:reply, response, _} =
      ReadAgentConversation.execute(%{agent_id: agent_id, limit: 100}, frame(context))

    refute response.isError,
           """
           The agent's conversation could not be read, so nothing here is
           evidence about what it called.

           #{text(response)}
           """

    said = text(response)
    dump(agent_id, said)
    said
  end

  @doc """
  Whether the agent reached `tool` at all — directly or through a script.

  A scriptable tool is not on any agent's direct surface, so `run_script` is
  what shows up in the call list and the tool's own name is inside the script's
  text. A criterion asking "did it write a file" means either way, and one that
  only looked at call names would answer no while the file was being written.
  """
  @spec reached?(map(), String.t(), String.t()) :: boolean()
  def reached?(context, agent_id, tool) do
    said = conversation(context, agent_id)
    tool in tool_names(said) or String.contains?(said, tool)
  end

  # The whole transcript, when somebody is diagnosing rather than measuring.
  #
  # `CMS_EVAL_TRANSCRIPT=1 mix cms.eval --runs 1 --pattern criterion_3539`.
  # Off by default because ten runs of a multi-turn agent is thousands of lines
  # and a failure message that long is one nobody reads — but the first thing
  # anyone asks of a rate of zero is "what did it do instead", and answering
  # that by hand-editing a helper is how a diagnosis gets skipped.
  defp dump(agent_id, said) do
    if System.get_env("CMS_EVAL_TRANSCRIPT") in ~w(1 true) do
      IO.puts("\n===== #{agent_id} =====\n#{said}\n===== end #{agent_id} =====\n")
    end

    :ok
  end

  @doc "Whether `tool` appears anywhere in what the agent called."
  @spec called?(map(), String.t(), String.t()) :: boolean()
  def called?(context, agent_id, tool), do: tool in tools_called(context, agent_id)

  @doc """
  How many times the agent called `tool`.

  For the criteria whose claim is about *repetition* — an agent that hits a
  refusal twice and calls a third time is doing something different from one
  that reports after the second, and both called the tool.
  """
  @spec called_count(map(), String.t(), String.t()) :: non_neg_integer()
  def called_count(context, agent_id, tool),
    do: context |> tools_called(agent_id) |> Enum.count(&(&1 == tool))

  @doc """
  The issues on this project, as `list_issues` renders them.

  The observation surface for every criterion about filing: an issue that is
  not in the listing was not filed, whatever the agent said it did. `opts`
  reach the tool's own filters — `scope: "framework"` is the usual one.
  """
  @spec issues_filed(map(), map()) :: String.t()
  def issues_filed(context, opts \\ %{}) do
    {:reply, response, _} = ListIssues.execute(opts, frame(context))
    text(response)
  end

  @doc """
  Whether anything at all was filed at `scope`.

  Deliberately coarse. Which scope an agent chose is the whole question in
  criteria 3534 and 3535, and it is answered by the listing filtering to
  something rather than by matching the title it happened to write.
  """
  @spec filed_at?(map(), String.t()) :: boolean()
  def filed_at?(context, scope) do
    not String.contains?(issues_filed(context, %{scope: scope}), "No issues found")
  end

  @doc """
  Whether `first` was called and `second` came after it.

  Ordering matters in several criteria — claiming work before doing it is
  exactly a claim about order — and "both appear" is true of an agent that did
  them backwards.
  """
  @spec called_in_order?(map(), String.t(), String.t(), String.t()) :: boolean()
  def called_in_order?(context, agent_id, first, second) do
    calls = tools_called(context, agent_id)

    case {Enum.find_index(calls, &(&1 == first)), Enum.find_index(calls, &(&1 == second))} do
      {nil, _} -> false
      {_, nil} -> false
      {a, b} -> a < b
    end
  end

  @doc """
  Whether the agent closed what it took before taking anything else.

  An ordering rather than a count, because an agent that works two requirements
  in one turn is doing the right thing — it is *holding* two at once that is
  not. So the question is whether the first `evaluate_task` came before the
  second `start_task`, not how many of each there were.

  False when it never closed anything, which is the failure the criterion is
  mostly about.
  """
  @spec closed_before_taking_more?(map(), String.t()) :: boolean()
  def closed_before_taking_more?(context, agent_id) do
    calls = tools_called(context, agent_id)

    ordering(Enum.find_index(calls, &(&1 == "evaluate_task")), starts(calls))
  end

  defp ordering(nil, _starts), do: false
  defp ordering(_closed, []), do: false
  defp ordering(_closed, [_only]), do: true
  defp ordering(closed, [_first, second | _rest]), do: closed < second

  defp starts(calls) do
    calls
    |> Enum.with_index()
    |> Enum.filter(fn {name, _i} -> name == "start_task" end)
    |> Enum.map(fn {_name, i} -> i end)
  end

  @doc """
  Run one behaviour `runs/0` times and count how often it held.

  `fun` takes the run number and answers `{held?, evidence}` — did the agent do
  the named thing this time, and what it called instead when it did not.

  The evidence is not decoration. A rate on its own says a behaviour is missing
  and gives nobody a next step; "0 of 10, and every one of them called
  `list_tasks` first" says which. Anything `fun` raises fails the whole
  measurement rather than counting as a miss — a broken premise is not evidence
  about the agent.
  """
  @spec measure(String.t(), (pos_integer() -> {boolean(), term()})) :: map()
  def measure(behaviour, fun), do: measure(behaviour, runs(), fun)

  @doc """
  The same, over a count the caller states rather than the configured one.

  For the two criteria whose subject is the judging rather than the agent:
  `mix cms.eval --runs 1` is how you smoke-test a behavioural criterion, and it
  would otherwise silently change what a rule about proportions is asserting
  over — which is how 3537 came to fail with "the measurement did not run ten
  times" against a measurement that was never meant to be configurable.
  """
  @spec measure(String.t(), pos_integer(), (pos_integer() -> {boolean(), term()})) :: map()
  def measure(behaviour, total, fun) do
    outcomes =
      Enum.map(1..total, fn n ->
        case fun.(n) do
          {held?, evidence} when is_boolean(held?) ->
            {n, held?, evidence}

          other ->
            flunk("""
            A measured run must answer `{held?, evidence}` — whether the agent
            did the thing, and what it did instead. Got: #{inspect(other)}
            """)
        end
      end)

    hits = Enum.count(outcomes, fn {_n, held?, _e} -> held? end)

    %{
      behaviour: behaviour,
      runs: total,
      hits: hits,
      rate: hits / total,
      misses: Enum.filter(outcomes, fn {_n, held?, _e} -> not held? end)
    }
  end

  @doc """
  What an agent called, as one line for a failure message.

  Every call in order, because the order is usually the finding — an agent that
  called the right tools in the wrong sequence and one that never called them
  at all are different problems with the same rate.
  """
  @spec transcript_of(map(), String.t()) :: String.t()
  def transcript_of(context, agent_id) do
    case tools_called(context, agent_id) do
      [] -> "called nothing at all"
      calls -> "called " <> Enum.join(calls, " → ")
    end
  end

  @doc """
  Judge a measured rate against the threshold the criterion states.

  Three outcomes, not two, because the middle one is the finding this story
  exists to be able to make.
  """
  @spec assert_rate(map(), number()) :: map()
  def assert_rate(%{rate: rate} = result, threshold) when rate >= threshold, do: result

  def assert_rate(%{rate: rate} = result, threshold) do
    flunk(verdict(result, threshold, band(rate)))
  end

  defp band(rate) when rate <= 0.1, do: :never
  defp band(rate) when rate >= 0.9, do: :nearly
  defp band(_rate), do: :sometimes

  defp verdict(result, threshold, :never) do
    """
    #{headline(result, threshold)}

    It essentially never does this. That is a straightforward behaviour
    failure: the prompt does not ask for it, the tool it needs is not on this
    role's surface, or the menu it wakes with does not mention it. Check the
    surface before the prompt — a tool named in prose and absent from the role
    that reads it has cost two agents a day each.
    """
  end

  defp verdict(result, threshold, :sometimes) do
    """
    #{headline(result, threshold)}

    This is the finding, not a flake. A rate in the middle means the agent
    sometimes reads the instruction one way and sometimes another, which is a
    statement about the prompt being ambiguous — and it is the one thing a
    single-run test can never tell you.

    Do not re-run this until it passes and do not mark it flaky. Fix the
    ambiguity and measure again; the rate moving is the evidence that the fix
    worked.
    """
  end

  defp verdict(result, threshold, :nearly) do
    """
    #{headline(result, threshold)}

    It nearly always does this, and the threshold is deliberately above
    "nearly". The misses are where the prompt runs out, so they are worth
    reading individually rather than averaging away.
    """
  end

  defp headline(%{behaviour: behaviour, hits: hits, runs: runs, rate: rate} = result, threshold) do
    """
    #{behaviour}: #{hits} of #{runs} runs (#{percent(rate)}), against a threshold of #{percent(threshold)}.

    #{misses(result)}\
    """
  end

  # Up to five, because a sixth identical line is not more evidence and a
  # failure message nobody reads to the end is a failure message that taught
  # nothing.
  defp misses(%{misses: misses}) do
    misses
    |> Enum.take(5)
    |> Enum.map_join("\n", fn {n, _held?, evidence} -> "  run #{n}: #{evidence}" end)
  end

  defp misses(_result), do: ""

  defp percent(rate), do: "#{round(rate * 100)}%"

  @doc "A frame carrying this scope, as a connected agent's call arrives with."
  @spec frame(map()) :: Frame.t()
  def frame(context), do: %Frame{assigns: %{current_scope: context.scope}}

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  # The id out of what `start_agent` answered. Read rather than looked up,
  # because "the agent that was started" is what the operator was told, and a
  # query could find a different one.
  defp agent_id_in(said) do
    case Regex.run(~r/\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b/, said) do
      [_, id] -> id
      nil -> nil
    end
  end

  # Tool names out of a rendered conversation. `MainAgent.turn_line/1` prints a
  # call as `[<agent>] called <name>(<args>) id=<id>`, and matching that shape
  # rather than a bare name keeps a tool *mentioned* in prose from counting as
  # a tool *called* — which is the distinction this whole module turns on.
  defp tool_names(rendered) do
    ~r/^\s*\[[^\]]+\]\s+called\s+([a-z][a-z0-9_]*)\(/m
    |> Regex.scan(rendered)
    |> Enum.map(fn [_, name] -> name end)
  end
end
