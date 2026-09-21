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
        judge: &called_in_order(&1, "get_next_requirement", "start_task")
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
  defp setup_world(_criterion) do
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

    %{root: root, scope: context.scope, context: context}
  end

  defp users, do: Module.concat([CodeMySpec, UsersFixtures])
  defp project_state, do: Module.concat([CodeMySpecSpex, ProjectStateFixtures])

  defp teardown_world(%{root: root}), do: File.rm_rf(root)

  # ------------------------------------------------------------- one measured run

  defp measure_once(criterion, world, run) do
    # Fresh work for every run, because the agents finish what they claim and a
    # consumed premise is not a premise. This is the whole reason the runner
    # owns its own world: a spex sets up once per scenario and cannot reseed
    # between measurements.
    seed_work(world, run)

    started = DateTime.utc_now()
    actionable = actionable_by_role(world.scope)

    outcome =
      case drive_agent(criterion, world) do
        {:ok, calls, usage} ->
          %{held?: criterion.judge.(calls), calls: calls, usage: usage, errored: nil}

        {:error, reason} ->
          %{held?: nil, calls: [], usage: nil, errored: inspect(reason)}
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

    {:ok, collector} = Elixir.Agent.start_link(fn -> %{calls: [], turn_ended?: false, usage: nil} end)

    try do
      with {:ok, agent_id} <- start_agent(criterion, world, collector),
           :ok <- request_turn(agent_id, world),
           {:ok, calls} <- await_judgement(collector, criterion) do
        # The behaviour is decided, but the agent is still working — it claimed
        # the requirement and went off to do it. Usage is only readable once the
        # turn ends, so wait a little for `:turn_ended` and record nothing
        # rather than wait for the job.
        # Usage rides on `:turn_ended` now, so it arrives rather than being
        # asked for. Asking was the problem: the loop answers busy mid-turn and
        # the agent is busy for minutes once it has claimed something.
        #
        # It is still absent by default, and that is a statement about *when*
        # rather than about the instrumentation: the behaviour is decided in
        # seconds and the turn runs on for minutes, because an agent that
        # claimed a requirement goes and does it. `CMS_EVAL_USAGE=1` waits for
        # the turn to close and pays the wall clock for the number.
        usage = maybe_await_usage(collector)
        machine().stop_agent(agent_id)
        {:ok, calls, usage}
      end
    after
      :ok

      case prior do
        nil -> Application.delete_env(:code_my_spec, :harness_mcp_scope)
        scope -> Application.put_env(:code_my_spec, :harness_mcp_scope, scope)
      end
    end
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

    case machine().start_agent(agent_id, world.root,
           provider: "claude-code",
           on_event: fn _agent_id, event -> record_event(collector, event) end
         ) do
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
  defp record_event(collector, %{event: :tool_start, payload: %{name: name}}) do
    Elixir.Agent.update(collector, fn c -> %{c | calls: c.calls ++ [name]} end)
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
      c |> Map.put(:turn_ended?, true) |> Map.put(:usage, Map.get(event, :usage))
    end)

    :ok
  end

  defp record_event(_collector, _event), do: :ok

  # Admission, the production trigger: continuous is standing intent and
  # `Work.request_turn_if_runnable/3` gives the turn when the graph has work for
  # the role. An answer naming no request is a premise failure, not conduct.
  defp request_turn(agent_id, world) do
    case SetAgentContinuous.execute(
           %{agent_id: agent_id, continuous: true},
           frame(world)
         ) do
      {:reply, %{isError: true} = r, _} ->
        {:error, {:continuous, text(r)}}

      {:reply, r, _} ->
        said = text(r)
        if said =~ "Nothing was requested", do: {:error, {:no_work, said}}, else: :ok
    end
  end

  # Wait for the conduct, not for the job. Decided as soon as the calls the
  # criterion asks about have happened, bounded so a run that never decides
  # reports rather than hangs.
  defp await_judgement(collector, criterion, deadline_ms \\ 180_000) do
    started = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      Process.sleep(500)
      calls = Elixir.Agent.get(collector, & &1.calls)
      {calls, criterion.judge.(calls), System.monotonic_time(:millisecond) - started}
    end)
    |> Enum.find(fn {_calls, decided?, elapsed} -> decided? or elapsed > deadline_ms end)
    |> then(fn {calls, _, _} -> {:ok, calls} end)
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

  # One story's worth of claimable coding work.
  #
  # Sealed through Three Amigos and released, which leaves `bdd_specs_exist`
  # actionable for coding. One agent claiming it does not take it from the next.
  defp seed_work(%{scope: scope, context: context}, run) do
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

  defp called_in_order(calls, first, second) do
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
