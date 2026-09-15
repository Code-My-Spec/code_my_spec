defmodule CodeMySpecTest.GraphHelpers do
  @moduledoc """
  Watching the graph move, and watching who got woken because it did.

  Every story in *Internal Agent Operation* and *Requirements Graph* turns on
  one of two observations: the graph reacted to something, or an agent was (or
  was deliberately not) told about it. Both were reachable before this module
  and neither was packaged — the recipe lived in one unit test, and a spex
  wanting the same claim had to re-derive it from
  `GraphWatcher`, `GraphInputs` and `RecordingAgentTransport` separately.

  ## The recipe this packages

      watch_graph(context)                      # ensure a watcher, subscribe
      # ... something happens: a file is written, an issue is filed ...
      settle_graph(context)                     # do the pending pass NOW
      assert_woken(coding_agent.id)
      refute_woken(qa_agent.id)

  ## Why `settle_graph/1` and never a sleep

  The watcher debounces, so a write does not recompute immediately. `settle/1`
  performs the pending pass synchronously instead of two seconds from now. A
  spec that slept would be asserting the timer rather than the mechanism, and
  would be flaky on a loaded box — which is where the analyzer runs.

  `settle/1` answers `:ok` when no watcher is running, so calling it against a
  project nothing is watching is not an error. That is also the trap: if you
  forget `watch_graph/1`, `settle_graph/1` succeeds, nothing recomputes, and
  the absence of a wake looks like correct role-scoping rather than a missing
  watcher. `assert_woken/2` names that possibility in its failure message.

  ## Why the negative assertion takes real time

  `refute_woken/2` cannot be immediate: "no message arrived" is only knowable
  after waiting. It drains for `:within` (default 300ms) and then reports. Keep
  it out of tight loops, and prefer asserting the positive case on one agent
  and the negative on one other — not the negative across a whole fleet.

  ## Requires the recording transport

  Wake deliveries are observed through `CodeMySpecTest.RecordingAgentTransport`,
  which routes to whichever process called `listen/0`. `install_recording_transport/1`
  does that and restores the previous transport on exit. The config key is
  global, so a spex using this must be `async: false`.
  """

  import ExUnit.Assertions

  alias CodeMySpec.Requirements.{GraphInputs, GraphWatcher}
  alias CodeMySpecTest.RecordingAgentTransport

  @default_within 300

  # Absence needs a window; presence needs patience. `refute_woken/2` keeps the
  # short one — it is answering "did nothing arrive", and waiting longer only
  # makes a passing suite slower. `assert_woken/2` waits far longer because it
  # returns the moment its message lands, so the number is a ceiling on failure
  # rather than a cost on success.
  @assert_within 5_000
  @default_timeout 2_000

  @doc """
  Start watching this project's graph and subscribe to its announcements.

  Both halves matter. `ensure_watching/1` is what makes a write recompute at
  all; the subscription is what lets `assert_graph_announced/2` see it.
  """
  def watch_graph(context) do
    scope = scope_of(context)
    {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    :ok = GraphInputs.subscribe(scope.active_project_id)
    drain_bootstrap_announcement(scope.active_project_id)
    context
  end

  # Starting a watcher computes the graph on arrival and announces it, so the
  # act of subscribing leaves a `{:graph_updated, _}` sitting in the caller's
  # mailbox. That is a real announcement — the graph went from nothing to
  # something — but it is not an *input* changing, which is what every caller
  # of these helpers is asking about. Left in place it fails
  # `refute_graph_announced/2` for a scenario that touched nothing.
  #
  # So the slate is clean by the time this returns: settle the bootstrap pass,
  # then drain what it announced.
  defp drain_bootstrap_announcement(project_id) do
    GraphWatcher.settle(project_id)

    receive do
      {:graph_updated, ^project_id} -> :ok
    after
      0 -> :ok
    end
  end

  @doc """
  Do the watcher's pending pass now rather than when the debounce expires.

  Call this after the thing you are claiming about, and before asserting.
  """
  def settle_graph(context) do
    :ok = GraphWatcher.settle(scope_of(context))
    context
  end

  @doc "Assert the graph announced a change on this project's topic."
  def assert_graph_announced(context, opts \\ []) do
    project_id = scope_of(context).active_project_id
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    receive do
      {:graph_updated, ^project_id} -> context
    after
      timeout ->
        flunk("""
        The graph never announced a change for project #{project_id}.

        Check in this order:
          1. `watch_graph/1` was called — without it nothing recomputes and
             nothing is subscribed.
          2. `settle_graph/1` was called after the change — the watcher
             debounces, so an un-settled write announces later than this.
          3. The thing you changed is actually a graph input. A write to a
             table the graph does not read moves nothing, which is a real
             answer and not a broken test.
        """)
    end
  end

  @doc """
  Assert the graph did NOT announce — that what you did was not a graph input.

  Waits `:within` (default #{@default_within}ms) before concluding.
  """
  def refute_graph_announced(context, opts \\ []) do
    project_id = scope_of(context).active_project_id
    within = Keyword.get(opts, :within, @default_within)

    receive do
      {:graph_updated, ^project_id} ->
        flunk(
          "The graph announced a change for #{project_id}, and this scenario says it should not have."
        )
    after
      within -> context
    end
  end

  @doc """
  Every wake delivered so far, as `{agent_id, message}`.

  Drains for `:within` so a delivery still in flight is not missed.
  """
  def woken(opts \\ []), do: drain(Keyword.get(opts, :within, @default_within), [])

  @doc """
  Assert this agent was woken, optionally that the message contained `:saying`.
  """
  def assert_woken(agent_id, opts \\ []) do
    saying = Keyword.get(opts, :saying)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :within, @assert_within)

    await_woken(agent_id, saying, deadline, [])
  end

  # Waits for the message it is about, rather than draining a window and
  # inspecting what happened to arrive.
  #
  # The old shape asserted the machine's speed. `settle_graph/1` answers as soon
  # as the graph is current, and the wake is published from a Task off the
  # watcher — deliberately, so a watcher waking inside its own recompute cannot
  # call itself — so delivery is *strictly after* the settle returns and how
  # long after is a property of the box. Draining 300ms and asserting over the
  # result failed about one run in eight under load, and the failures read as
  # routing defects rather than as timing.
  #
  # Lengthening the window does not fix it, which is the part worth keeping:
  # 500ms and 3000ms both measured 2-3 red in 10 on the same spec, because the
  # window was never the variable. Returning the instant the message arrives is,
  # and it costs the deadline only when the message genuinely never comes.
  defp await_woken(agent_id, saying, deadline, seen) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:agent_dispatch, id, _ref, message} ->
        keep_or_wait(matches?(id, message, agent_id, saying), {id, message}, %{
          agent_id: agent_id,
          saying: saying,
          deadline: deadline,
          seen: seen
        })
    after
      remaining -> never_woken(agent_id, saying, seen)
    end
  end

  defp matches?(id, _message, agent_id, nil), do: id == agent_id
  defp matches?(id, message, agent_id, saying), do: id == agent_id and message =~ saying

  defp keep_or_wait(true, delivered, _ctx), do: [delivered]

  defp keep_or_wait(false, delivered, ctx) do
    await_woken(ctx.agent_id, ctx.saying, ctx.deadline, [delivered | ctx.seen])
  end

  defp never_woken(agent_id, saying, seen) do
    flunk("""
    Agent #{agent_id} was not woken#{if saying, do: " with a message containing #{inspect(saying)}", else: ""}.

    Woken while waiting: #{describe(Enum.reverse(seen))}

    If nothing at all was woken, the likeliest cause is a missing
    `watch_graph/1` — `settle_graph/1` answers `:ok` when no watcher is
    running, so a forgotten watcher looks exactly like correct scoping.
    """)
  end

  @doc """
  Assert this agent was NOT woken — the role-scoping claim.

  Waits `:within` before concluding, because absence is only knowable by
  waiting. Prefer pairing this with an `assert_woken/2` on the agent that
  *should* have been told: a scenario where nobody was woken passes this
  assertion for the wrong reason.
  """
  def refute_woken(agent_id, opts \\ []) do
    delivered = woken(opts)

    case Enum.filter(delivered, fn {id, _} -> id == agent_id end) do
      [] ->
        :ok

      [{_, message} | _] ->
        flunk("""
        Agent #{agent_id} was woken and this scenario says it should not have been.

        It was told: #{inspect(message)}

        Everything woken during this window: #{describe(delivered)}
        """)
    end
  end

  @doc """
  Install the recording transport and route deliveries here.

  Restores the previous transport on exit rather than assuming the default —
  the config key is global, so a spex using this must be `async: false`.
  """
  def install_recording_transport(context) do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    RecordingAgentTransport.listen()

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:code_my_spec, :agent_transport)
        module -> Application.put_env(:code_my_spec, :agent_transport, module)
      end
    end)

    context
  end

  defp drain(within, acc) do
    receive do
      {:agent_dispatch, id, _ref, message} -> drain(within, [{id, message} | acc])
      {:agent_message, id, message} -> drain(within, [{id, message} | acc])
    after
      within -> Enum.reverse(acc)
    end
  end

  defp describe([]), do: "nothing"

  defp describe(delivered) do
    Enum.map_join(delivered, fn {id, message} ->
      "\n    #{id} <- #{inspect(String.slice(to_string(message), 0, 80))}"
    end)
  end

  defp scope_of(%{scope: scope}), do: scope
  defp scope_of(%CodeMySpec.Users.Scope{} = scope), do: scope
end
