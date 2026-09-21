defmodule CodeMySpec.Support.EvalRunner do
  @moduledoc """
  Runs behavioural evals and writes down what the agent did.

  Not a test. `mix cms.eval` calls this, it stands its own world up on disk, it
  drives real agents against a real model, and it writes an artifact per run.
  `mix spex` then asserts on those artifacts and never calls a model.

  ## Why this is not a spex

  It was one, and every wall it hit was a spex's wall rather than an eval's.

  A spex runs inside ExUnit with the Ecto sandbox, and its environment is
  `Support.InMemoryEnvironment` — `Environments.write_file/3` answers `:ok` and
  puts nothing on disk. That is right for a scenario driving a LiveView and
  exactly wrong for one driving an agent, because a real agent reads real files
  with a real `Read` tool. The fixture and the agent were looking at two
  different filesystems, so the project chain never closed at the agent's
  vantage, `technical_strategy` was the only actionable requirement in the
  world, and the first run consumed it. At n=10 run 2 found `main: []`.

  So the runner owns its setup: a real directory, real files, a disk-backed
  environment, no sandbox. Nothing here is bounded by what a spex can express.

  ## What it produces

  One artifact per run under `test/fixtures/evals/<criterion>/<run>.json`,
  beside the cassettes and for the same reason — a recording of an expensive
  real interaction, committed so the assertion is cheap and auditable by
  somebody other than whoever ran it.
  """

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous
  alias CodeMySpec.Requirements
  alias CodeMySpec.Users.Scope

  @artifact_root "test/fixtures/evals"

  @doc """
  Run every criterion matching `:pattern`, `:runs` times each.

  Answers a report rather than raising: a run that errored is not evidence
  about the agent and the caller decides what to do about it.
  """
  @spec run(keyword()) :: %{criteria: list(), artifact_root: String.t()}
  def run(opts \\ []) do
    runs = Keyword.get(opts, :runs, 10)
    pattern = Keyword.get(opts, :pattern)

    criteria = Enum.filter(criteria(), &matches?(&1, pattern))

    results =
      Enum.map(criteria, fn criterion ->
        world = setup_world(criterion)
        outcomes = Enum.map(1..runs, &measure_once(criterion, world, &1))
        teardown_world(world)

        %{criterion: criterion.id, behaviour: criterion.behaviour, outcomes: outcomes}
      end)

    %{criteria: results, artifact_root: @artifact_root}
  end

  @doc """
  The criteria this runner knows how to measure.

  Data rather than modules on purpose: a criterion is a behaviour, a threshold
  and a way to judge one transcript, and none of that needs a module to live in.
  """
  @spec criteria() :: [map()]
  def criteria do
    [
      %{
        id: "criterion_3539",
        behaviour: "An agent starts work by asking what work there is",
        role: "coding",
        threshold: 0.9,
        deadline_ms: 180_000,
        seed: &seed_coding_work/2,
        judge: &called_in_order(&1, "get_next_requirement", "start_task")
      },
      %{
        id: "criterion_3540",
        behaviour: "An agent that finishes work closes the task",
        # Product and a link, not coding and a spec suite.
        #
        # This criterion is about *closing*, and any claimable work will do — so
        # the premise should be work an agent can plausibly finish. The first
        # run handed it `bdd_specs_exist` and watched it work honestly for the
        # whole 180-second deadline: tool_docs, five reads, two scripts, bash,
        # more reads. It was writing the specs. It never got to `evaluate_task`
        # because it had not finished, which says nothing about whether it
        # closes what it takes.
        #
        # `component_linked` is one call's worth of work on an unlinked story.
        role: "product",
        threshold: 0.9,
        deadline_ms: 300_000,
        seed: &seed_unlinked_story/2,
        judge: &closed_before_taking_more?/1
      },
      %{
        id: "criterion_3542",
        behaviour: "An agent with no work of its kind stops rather than inventing some",
        # Coding on a checkout with nothing authored on it — the ordinary way an
        # agent finds itself idle, rather than a project whose work has been
        # consumed, which is a different state and one where it can still see
        # what the work was.
        role: "coding",
        world: :bare,
        # The turn has to come from a person. `StopDecision.wake/2` renders the
        # menu and stays silent for a role with an empty one, deliberately, so
        # an idle agent costs nothing — switching this agent on sends it nothing
        # and it never speaks. What the criterion is about is the turn an idle
        # agent *does* get. "Carry on." names neither a tool nor tapping out,
        # because naming either would be telling it the answer.
        say: "Carry on.",
        threshold: 0.9,
        deadline_ms: 180_000,
        seed: fn _world, _run -> :ok end,
        judge: &asked_to_leave?/1
      }
    ]
  end

  # ---------------------------------------------------------------- the world

  # A project on disk, seeded so the role under test has claimable work.
  #
  # `full_scope_fixture/0` already builds a `:local` environment on a real temp
  # directory — the `:memory` one a spex gets comes from its Case, not from
  # here. So the fixture's writes and the agent's reads are the same filesystem,
  # which is the whole reason this runner exists.
  defp setup_world(criterion) do
    case Map.get(criterion, :world, :full_satisfaction) do
      :full_satisfaction -> full_satisfaction_world()
      :bare -> bare_world()
    end
  end

  # A checkout with nothing authored on it, for the criteria about an agent with
  # nothing to do. No fixture, no sync: the graph is empty because there is
  # nothing to compute one from, which is the state being measured.
  defp bare_world do
    scope = users().full_scope_fixture()
    root = scope.environment.cwd
    scope = %Scope{scope | cwd: root}
    File.mkdir_p!(Path.join(root, ".code_my_spec"))

    Requirements.recompute(scope)
    settle(scope)

    %{root: root, scope: scope, context: %{scope: scope}}
  end

  defp full_satisfaction_world do
    scope = users().full_scope_fixture()
    root = scope.environment.cwd
    scope = %Scope{scope | cwd: root}

    context = %{
      scope: scope,
      environment: scope.environment,
      project: scope.active_project
    }

    # `FullSatisfactionFixtures.apply/1` rather than a hand-built graph.
    #
    # It is the fixture the spex already use for a fully satisfied project:
    # project setup, artifact files, a component with spec and implementation
    # synced, a story linked with criteria and a persona, a BDD spec, and the QA
    # artifacts. Assembling that by hand here reproduced its bugs instead of its
    # behaviour — a component created as a row is not covered by
    # `architecture_designed`, whose own description asks for "every component
    # covered (story-linked, transitively depended on, or infrastructure)".
    context =
      context
      |> Map.put(:conn, Phoenix.ConnTest.build_conn())
      |> full_satisfaction().apply()

    # Publish what the fixture wrote and compute the graph over it. Both
    # explicit, because nothing else is going to do them: there is no
    # `FileWatcherServer` here and reads serve rows rather than computing.
    {:ok, _} = FileSync.sync(scope, base_dir: root, embed: false)
    {:ok, _} = ComponentSync.sync_from_files(scope, base_dir: root)
    Requirements.recompute(scope)

    # Then wait for the echo, which is not optional.
    #
    # `FileSync.sync/2` publishes one file at a time, `GraphWatcher` debounces
    # the burst into a recompute, and that recompute spawns
    # `Work.consider_project/2` under `CodeMySpec.TaskSupervisor` for every
    # vantage it moved. Those tasks are still running when the calls above
    # return.
    #
    # Run 1 of every measurement was being taken inside that storm. On 3540 it
    # asked `get_next_requirement` twice, got a pool error both times, and
    # reported it — correctly — as infrastructure rather than improvising
    # around it; the run scored False at the 300-second deadline while runs 2
    # and 3 of the same batch passed in 73 seconds on the same pool. Neither
    # the agent nor the pool was at fault. The runner was measuring while its
    # own setup was still landing, and only the first run ever paid for it.
    # `context.scope` rather than `scope`: the fixture may have moved the
    # vantage, and the world hands this one to the agent.
    settle(context.scope)

    %{root: root, scope: context.scope, context: context}
  end

  # Every vantage's pending graph work, drained.
  #
  # `CodeMySpecSpex.Fixtures.settle_graph/1` is the approved bridge and already
  # does exactly this — `GraphWatcher.settle/1`, then drain the task supervisor
  # — so the runner borrows it rather than growing a second one to drift from.
  defp settle(scope), do: :ok = fixtures().settle_graph(scope)

  defp users, do: Module.concat([CodeMySpec, UsersFixtures])
  defp project_state, do: Module.concat([CodeMySpecSpex, ProjectStateFixtures])
  defp fixtures, do: Module.concat([CodeMySpecSpex, Fixtures])

  defp teardown_world(%{root: root}), do: File.rm_rf(root)

  # ------------------------------------------------------------- one measured run

  defp measure_once(criterion, world, run) do
    # Fresh work for every run, because the agents finish what they claim and a
    # consumed premise is not a premise. This is the whole reason the runner
    # owns its own world: a spex sets up once per scenario and cannot reseed
    # between measurements.
    criterion.seed.(world, run)

    # The seed writes and recomputes too, so it has an echo of its own — same
    # reason as `setup_world/1`, and a run measured during it measures the
    # storm rather than the agent.
    settle(world.scope)

    started = DateTime.utc_now()
    actionable = actionable_by_role(world.scope)

    outcome =
      case drive_agent(criterion, world) do
        {:ok, calls, usage, trace} ->
          %{
            # Judged on the record that is written down, so the artifact and the
            # verdict cannot disagree.
            held?: criterion.judge.(%{calls: calls, trace: trace}),
            calls: calls,
            usage: usage,
            trace: trace,
            errored: nil
          }

        {:error, reason} ->
          %{held?: nil, calls: [], usage: nil, trace: [], errored: inspect(reason)}
      end

    outcome =
      Map.merge(outcome, %{
        criterion: criterion.id,
        behaviour: criterion.behaviour,
        role: criterion.role,
        run: run,
        at: started,
        seconds: DateTime.diff(DateTime.utc_now(), started),
        root: world.root,
        actionable: actionable,
        unsatisfied: unsatisfied_sample(world.scope)
      })

    write_artifact(criterion.id, run, outcome)
    outcome
  end

  # Start an agent, let admission give it a turn, and read back what it called.
  #
  # No harness channel. `InVmMcpTransport` dispatches in-process and takes the
  # agent's scope from `:harness_mcp_scope`, so the MCP half of the tool surface
  # needs no working-copy join at all. The disk half — Alloy's Read, Write, Edit
  # and Bash — reads `:working_directory`, which is why the world is a real
  # directory even when the graph would not have required one.
  defp drive_agent(criterion, world) do
    prior = Application.get_env(:code_my_spec, :harness_mcp_scope)
    Application.put_env(:code_my_spec, :harness_mcp_scope, world.scope)

    {:ok, collector} =
      Elixir.Agent.start_link(fn ->
        %{calls: [], turn_ended?: false, usage: nil, trace: [], in_flight: 0}
      end)

    try do
      with {:ok, agent_id} <- start_agent(criterion, world, collector),
           :ok <- request_turn(agent_id, world, criterion),
           {:ok, calls} <- await_judgement(collector, criterion) do
        # Usage rides on `:turn_ended`, so it arrives rather than being asked
        # for. Asking was the problem: the loop answers busy mid-turn, and an
        # agent that claimed a requirement is busy for minutes doing it.
        #
        # Absent by default, and that is a statement about *when* rather than
        # about the instrumentation — the behaviour is decided in seconds and
        # the turn runs on. `CMS_EVAL_USAGE=1` waits for the turn to close and
        # pays the wall clock for the number.
        await_quiet(collector)
        usage = maybe_await_usage(collector)
        trace = Elixir.Agent.get(collector, & &1.trace)
        machine().stop_agent(agent_id)
        retire(agent_id, world)
        {:ok, calls, usage, trace}
      end
    after
      :ok

      case prior do
        nil -> Application.delete_env(:code_my_spec, :harness_mcp_scope)
        scope -> Application.put_env(:code_my_spec, :harness_mcp_scope, scope)
      end
    end
  end

  # A story with no component, which leaves `component_linked` open for product.
  #
  # The smallest claimable thing the graph offers: one `set_story_component`
  # call and it is done. Small on purpose — a criterion about closing work needs
  # work that can be closed inside a measurement.
  defp seed_unlinked_story(%{scope: scope}, run) do
    story_helpers().create_story(scope,
      title: "Eval link #{run}",
      description: "A story whose component nobody has chosen",
      acceptance_criteria: ["It is linked to the component that implements it"]
    )

    Requirements.recompute(scope)
    :ok
  end

  # Take the agent's row away when its run is over.
  #
  # Stopping the process is not enough: the row survives with its claim on it,
  # and `TaskOwner.check_requirement_claim/2` refuses a later claim on the same
  # requirement by anyone else sharing the copy — `task_owned_by_another_agent`.
  #
  # Measured at n=10 on 3540. Runs 4 through 8 were identical: claim refused,
  # the agent correctly reported that the only surfaced requirement was "already
  # claimed by another agent... so I am stopping here rather than retrying the
  # same claim", and stopped. The other agent was the previous run's, stopped
  # minutes earlier and still holding.
  #
  # Runs are only independent if nothing an agent did survives into the next
  # one, and a claim is the longest-lived thing it leaves behind.
  defp retire(agent_id, world) do
    case CodeMySpec.Agents.AgentsRepository.fetch_agent(world.scope, agent_id) do
      {:ok, agent} -> CodeMySpec.Repo.delete(agent)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # ------------------------------------------------------- driving one agent
  #
  # Every step answers a tagged tuple rather than asserting. A runner is not a
  # test: a premise that does not hold is a run that measured nothing, and the
  # caller decides what that means.

  # Started through `Machine.launch/1` rather than the `start_agent` MCP tool.
  #
  # The tool goes over the transport, and `on_event` is a function — it cannot
  # cross a wire, which is exactly why the engine keeps it machine-local. The
  # callback is the only way to see a turn as it happens.
  #
  # That matters because the engine will not hand over its history mid-turn:
  # `history/1` is a `GenServer.call` into the loop and answers `{:error, :busy}`
  # while a turn is running, deliberately — "an agent that cannot be sent
  # anything while somebody reads its history is the failure the turn-in-a-task
  # shape exists to avoid". So polling cannot work, and waiting for the agent to
  # finish means waiting for the whole job: one measured at 275 seconds and was
  # still going, because it had claimed `bdd_specs_exist` and gone off to write
  # the specs.
  #
  # The criterion is about the first turn. `on_event` gives it in seconds.
  defp start_agent(criterion, world, collector) do
    {:ok, agent} =
      AgentsRepository.create_agent(world.scope, %{
        engine: :alloy,
        provider: "claude-code",
        role: criterion.role,
        working_copy: world.root,
        working_copy_id: world.scope.active_working_copy_id,
        status: :running,
        continuous: true
      })

    # The row's own id, not one generated here: `create_agent/2` mints it, and
    # naming a different one leaves `set_agent_continuous` answering "No agent
    # on this project has that id".
    agent_id = agent.id

    # Launched with the request the *server* builds, not the bare map
    # `Machine.start_agent/3` assembles.
    #
    # That helper sends `agent_id`, `working_copy`, `provider` and nothing else,
    # so `universal`, `role_brief`, `tool_index`, `project_brief` and
    # `provider_brief` all arrived nil and `SystemPrompt.compose/1` answered
    # `nil`. Every eval so far measured an agent with **no system prompt at
    # all** — no loop, no role, no tool index — while a production agent gets
    # all five. The criteria were scoring a different agent than the one that
    # ships, and a prompt change could not move a rate because the prompt was
    # not reaching the model.
    #
    # Found on 3542: the rule telling an idle agent to `tap_out` was added to
    # `OperatingRules`, the run was taken again, and nothing changed — because
    # `OperatingRules.text()` was never in the request.
    request =
      world.scope
      |> launch_request().hydrate(agent)
      |> launch_request().for()
      |> Map.merge(%{
        "api_key" => "unused-in-eval",
        "on_event" => fn _agent_id, event -> record_event(collector, event) end
      })

    case machine().launch(request) do
      {:ok, _} -> {:ok, agent_id}
      other -> {:error, {:start_agent, other}}
    end
  end

  # Every tool call the agent makes, in order, as it makes them.
  #
  # `:tool_start` carries `payload.name`, and the events arrive with a `seq`, so
  # this is the order the agent actually called things in rather than an order
  # reconstructed from prose. A model will narrate a call it never made; only
  # one of those shows up here.
  defp record_event(collector, %{event: :tool_start, payload: %{name: name}} = event) do
    Elixir.Agent.update(collector, fn c ->
      %{
        c
        | calls: c.calls ++ [name],
          trace: c.trace ++ [summarise(event)],
          in_flight: c.in_flight + 1
      }
    end)

    :ok
  end

  # The other half of the count, so the runner can tell a call that has been
  # made from one that has finished. See `await_quiet/2`.
  defp record_event(collector, %{event: :tool_end} = event) do
    Elixir.Agent.update(collector, fn c ->
      %{c | trace: c.trace ++ [summarise(event)], in_flight: max(c.in_flight - 1, 0)}
    end)

    :ok
  end

  # Token spend, read at the one moment the engine is not busy.
  #
  # `Alloy.Server.usage/1` is a call into the loop, and the loop answers
  # `{:error, :busy}` mid-turn — the same reason `history/1` cannot be polled.
  # `:turn_ended` is emitted from the engine after the turn has completed, so
  # asking here is the one place it answers.
  defp record_event(collector, %{event: :turn_ended} = event) do
    Elixir.Agent.update(collector, fn c ->
      c
      |> Map.put(:turn_ended?, true)
      |> Map.put(:usage, Map.get(event, :usage))
      |> Map.put(:trace, c.trace ++ [summarise(event)])
    end)

    :ok
  end

  # Everything else, kept as a trace.
  #
  # The artifact lost its transcript when usage went in, and the very next run
  # could not be diagnosed: the agent asked twice and never claimed, and there
  # was nothing to read. `running_evals.md` says to read the transcript every
  # iteration, which is only possible if the artifact holds one.
  defp record_event(collector, event) do
    Elixir.Agent.update(collector, fn c ->
      %{c | trace: c.trace ++ [summarise(event)]}
    end)

    :ok
  end

  # Small enough to read, complete enough to diagnose.
  #
  # What the agent *said* matters as much as what it called: the first traced
  # run of 3540 showed `get_next_requirement` twice, a message, and the turn
  # ending — and the message was the only thing that could say why it had
  # looked at its work and walked away. It came through blank, because this
  # only knew how to read `payload.name`.
  #
  # So: the name for a call, the answer for a result, the words for a message,
  # and the whole event when it is none of those. Sliced, because a tool result
  # can be the entire requirements graph and the point is to be readable.
  defp summarise(event) when is_map(event) do
    %{event: Map.get(event, :event, :unknown), detail: detail_of(event)}
  end

  defp summarise(other), do: %{event: :unknown, detail: inspect(other, limit: 6)}

  defp detail_of(%{payload: %{name: name, input: input}}) when input != %{},
    do: "#{name} #{slice(inspect(input, limit: 8))}"

  defp detail_of(%{payload: %{name: name}}), do: name
  defp detail_of(%{payload: %{result: result}}), do: slice(to_string_safe(result))
  defp detail_of(%{payload: %{output: output}}), do: slice(to_string_safe(output))
  defp detail_of(%{payload: %{text: text}}), do: slice(to_string_safe(text))
  defp detail_of(%{payload: %{content: content}}), do: slice(to_string_safe(content))
  defp detail_of(%{payload: payload}), do: slice(inspect(payload, limit: 10))
  defp detail_of(%{message: message}), do: slice(to_string_safe(message))

  defp detail_of(event) do
    event
    |> Map.drop([:event, :v, :seq, :ts_ms, :correlation_id])
    |> inspect(limit: 10)
    |> slice()
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value, limit: 10)

  defp slice(text), do: String.slice(text, 0, 700)

  # Admission, the production trigger: continuous is standing intent and
  # `Work.request_turn_if_runnable/3` gives the turn when the graph has work for
  # the role. An answer naming no request is a premise failure, not conduct.
  defp request_turn(agent_id, world, criterion) do
    with :ok <- put_in_loop(agent_id, world, criterion) do
      case Map.get(criterion, :say) do
        nil -> :ok
        said -> say(agent_id, said)
      end
    end
  end

  defp put_in_loop(agent_id, world, criterion) do
    case SetAgentContinuous.execute(
           %{agent_id: agent_id, continuous: true},
           frame(world)
         ) do
      {:reply, %{isError: true} = r, _} ->
        {:error, {:continuous, text(r)}}

      {:reply, r, _} ->
        said = text(r)

        cond do
          not (said =~ "Nothing was requested") -> :ok
          # For a criterion measuring an idle agent, being sent nothing is the
          # premise rather than a broken one — the loop is silent for an empty
          # menu on purpose, and the turn comes from the operator instead.
          Map.has_key?(criterion, :say) -> :ok
          true -> {:error, {:no_work, said}}
        end
    end
  end

  # Tell a running agent something, the way an operator's message reaches it,
  # without waiting for the turn — `await_judgement/2` is what watches it
  # happen, and waiting here would mean waiting for the whole job.
  defp say(agent_id, said) do
    case machine().send_message(agent_id, Ecto.UUID.generate(), said) do
      {:ok, _} -> :ok
      other -> {:error, {:say, other}}
    end
  end

  # Wait for the conduct, not for the job. Decided as soon as the calls the
  # criterion asks about have happened, bounded so a run that never decides
  # reports rather than hangs.
  #
  # A closed turn also ends the wait, because the criteria are about the first
  # turn and an agent that has finished one is not about to add a call to it.
  # Without that, a run the agent decides in twenty seconds still costs the
  # whole deadline — 3542 sat for 180 seconds after the agent had stopped, and
  # a failing measurement is the one you take most often while fixing it.
  defp await_judgement(collector, criterion) do
    deadline_ms = Map.get(criterion, :deadline_ms, 180_000)

    started = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      Process.sleep(500)
      state = Elixir.Agent.get(collector, & &1)

      {state.calls, criterion.judge.(state), state.turn_ended?,
       System.monotonic_time(:millisecond) - started}
    end)
    |> Enum.find(fn {_calls, decided?, ended?, elapsed} ->
      decided? or ended? or elapsed > deadline_ms
    end)
    |> then(fn {calls, _, _, _} -> {:ok, calls} end)
  end

  # Let in-flight tool calls land before anything is torn down.
  #
  # `await_judgement/2` decides on `:tool_start`, which is right — the criterion
  # is about what the agent called — but it means the call it judged is still
  # executing when it returns. Stopping the agent and deleting its row then
  # races that call.
  #
  # Measured on 3540: the agent linked the story, called `evaluate_task`, and
  # the judge was satisfied by the `tool_start`. `retire/2` deleted the agent
  # row while the tool was running, so `TaskOwner.complete_task/4` could not
  # find its owner and the tool crashed with `{:error, :owner_not_found}` —
  # *after* evaluating the work as valid. The run scored True and the task it
  # was closing never closed. A criterion about closing work cannot be measured
  # by a runner that prevents the close.
  #
  # Bounded, because a tool that never returns is a finding rather than
  # something to wait out.
  defp await_quiet(collector, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Process.sleep(250)
      {Elixir.Agent.get(collector, & &1.in_flight), System.monotonic_time(:millisecond)}
    end)
    |> Enum.find(fn {in_flight, now} -> in_flight == 0 or now > deadline end)

    :ok
  end

  # What it called, in order. Off the messages rather than out of prose: a model
  # will narrate a call it never made, and only one of those is evidence.
  defp tool_names(history) when is_list(history) do
    Enum.flat_map(history, fn
      %{tool_calls: calls} when is_list(calls) ->
        Enum.map(calls, fn
          %{name: name} -> name
          %{"name" => name} -> name
          other -> inspect(other)
        end)

      _ ->
        []
    end)
  end

  defp tool_names(_), do: []

  defp agent_id_from(said) do
    case Regex.run(~r/\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b/, said) do
      [_, id] -> {:ok, id}
      _ -> {:error, {:no_agent_id, said}}
    end
  end

  defp frame(world) do
    %Anubis.Server.Frame{assigns: %{current_scope: world.scope}}
  end

  defp text(response) do
    response
    |> Anubis.Server.Response.to_protocol()
    |> Map.fetch!("content")
    |> hd()
    |> Map.fetch!("text")
  end

  # Present when the turn closed before we stopped watching, `nil` when it did
  # not — never a zero, because "no spend recorded" and "spend was zero" are
  # different facts and only one of them is true here.
  defp maybe_await_usage(collector) do
    if System.get_env("CMS_EVAL_USAGE") in ~w(1 true) do
      deadline = System.monotonic_time(:millisecond) + 600_000

      Stream.repeatedly(fn ->
        Process.sleep(1_000)
        {Elixir.Agent.get(collector, & &1), System.monotonic_time(:millisecond)}
      end)
      |> Enum.find(fn {c, now} -> c.turn_ended? or now > deadline end)
      |> then(fn {c, _} -> c[:usage] end)
    else
      Elixir.Agent.get(collector, & &1[:usage])
    end
  end

  defp machine, do: Module.concat([CmsHarnessTest, Machine])
  defp launch_request, do: Module.concat([CodeMySpec, Agents, LaunchRequest])

  # One story's worth of claimable coding work.
  #
  # Sealed through Three Amigos and released, which leaves `bdd_specs_exist`
  # actionable for coding. One agent claiming it does not take it from the next.
  defp seed_coding_work(%{scope: scope, context: context}, run) do
    # Linked and released directly rather than through `StoryHelpers`.
    #
    # `set_component/3` drives the MCP tool and discards its reply, so a link
    # that did not happen is silent — which is what left `component_linked`
    # actionable and `architecture_designed` with an uncovered component behind
    # it. The requirement's own description says why that gate matters: "every
    # component is covered (story-linked, transitively depended on, or
    # infrastructure)".
    story =
      story_helpers().create_story(scope,
        title: "Eval work #{run}",
        description: "Claimable coding work for one measured run",
        acceptance_criteria: ["The agent claims this before doing it"]
      )

    story = CodeMySpec.Stories.get_story!(scope, story.id)

    {:ok, story} =
      CodeMySpec.Stories.update_story(scope, story, %{
        component_id: context.component.id,
        ready_for_dev: true
      })

    :ok =
      project_state().apply_three_amigos_for_story(scope, story, persona_id: context.persona_id)

    Requirements.recompute(scope)
    story
  end

  defp story_helpers, do: Module.concat([CodeMySpecSpex, StoryHelpers])
  defp full_satisfaction, do: Module.concat([CodeMySpecSpex, FullSatisfactionFixtures])

  # Everything the graph still wants, so a premise failure names itself.
  defp unsatisfied_sample(scope) do
    scope
    |> Requirements.actionable_for_role(nil)
    |> Enum.map(&"#{&1.name} (#{&1.entity_type})")
  end

  # What the graph holds for each role at this world's checkout — the same
  # answer admission reads, so an empty set is a premise failure and not a
  # finding about the agent.
  defp actionable_by_role(scope) do
    Map.new([:coding, :main, :product, :qa], fn role ->
      names =
        scope
        |> Requirements.actionable_for_role(role)
        |> Enum.map(& &1.name)

      {role, names}
    end)
  end

  # ------------------------------------------------------------------ judging

  # Closed what it took, before taking anything else.
  #
  # One claim and a close is right; a second claim before the close is the
  # failure — an agent that abandons work half-done leaves a task nobody can
  # evaluate and a requirement nobody is on.
  defp closed_before_taking_more?(%{calls: calls}) do
    closed = Enum.find_index(calls, &(&1 == "evaluate_task"))

    starts =
      calls
      |> Enum.with_index()
      |> Enum.filter(fn {name, _i} -> name == "start_task" end)
      |> Enum.map(fn {_name, i} -> i end)

    case {closed, starts} do
      {nil, _} -> false
      {_, []} -> false
      {_, [_only]} -> true
      {closed, [_first, second | _]} -> closed < second
    end
  end

  # Tapping out, and neither of the two ways of inventing work.
  #
  # `tap_out` exists for exactly this and asks a person rather than deciding, so
  # calling it is the right answer and stopping silently is not: a silent stop
  # is indistinguishable from a crash from every surface there is.
  #
  # The two negatives are separately load-bearing. Taking another role's task is
  # how an idle coding agent ends up doing QA badly, and writing files nobody
  # asked for is 3545 arriving by a different road.
  defp asked_to_leave?(%{calls: calls} = record) do
    "tap_out" in calls and
      "start_task" not in calls and
      not reached?(record, "write_project_file")
  end

  # Whether the agent reached a tool, including through `run_script` — code mode
  # means the name shows up in a script rather than as a call of its own.
  #
  # `tool_docs` is excluded on purpose. Its argument is a list of names the
  # agent is asking *about*, so counting it would score an agent that read the
  # documentation and then correctly decided not to act as though it had acted.
  # Reading about a tool is not reaching for one.
  defp reached?(%{calls: calls, trace: trace}, name) do
    name in calls or
      Enum.any?(trace, fn event ->
        detail = Map.get(event, :detail, "")

        is_binary(detail) and
          not String.starts_with?(detail, "tool_docs") and
          String.contains?(detail, name)
      end)
  end

  defp called_in_order(%{calls: calls}, first, second) do
    with i when not is_nil(i) <- Enum.find_index(calls, &(&1 == first)),
         j when not is_nil(j) <- Enum.find_index(calls, &(&1 == second)) do
      i < j
    else
      _ -> false
    end
  end

  # ---------------------------------------------------------------- artifacts

  defp write_artifact(criterion_id, run, outcome) do
    dir = Path.join(@artifact_root, criterion_id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "#{run}.json"),
      Jason.encode!(outcome, pretty: true)
    )
  end

  defp matches?(_criterion, nil), do: true
  defp matches?(criterion, pattern), do: String.contains?(criterion.id, pattern)
end
