defmodule CodeMySpec.Agents.WakeTest do
  @moduledoc """
  a31f1cd6 step 4a: one "allow wake" decision. John: "is the agent on? yes. Is
  the agent continuous? yes. Is this answer relevant to this agent? yes. OK
  then we wake the agent."

  Every role × event kind × agent state, against the table written out here
  from what each path did before the decision existed.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence

  # Who hears what nobody else does. Everything else is relevant to everyone:
  # a person's message and the answers to the agent's own requests.
  @relevant %{
    main: [
      :work_offer,
      :nudge,
      :resume,
      :teammate_question,
      :findings,
      :cadence,
      :teammate_stalled,
      :teammate_died
    ],
    product: [:work_offer, :nudge, :resume, :teammate_question],
    coding: [:work_offer, :nudge, :resume, :findings],
    qa: [:work_offer, :nudge, :resume]
  }
  # A held-back offer is main's own administrative notice, like :team_free: told
  # whatever the role, and told now rather than held for a non-continuous main
  # (criterion 2063). It is deliberately not in @puts_to_work -- the point is
  # that it wakes an agent that is not continuous.
  @always [
    :operator_message,
    :own_reply,
    :question_answered,
    :blocker_resolved,
    :team_free,
    :offer_held_back
  ]

  # A non-continuous agent is woken only by a person and its own replies
  # (step 4b, John: "hold them"); what it asked for is handed it inside a turn.
  @puts_to_work [
    :work_offer,
    :resume,
    :teammate_question,
    :nudge,
    :findings,
    :cadence,
    :teammate_stalled,
    :teammate_died
  ]
  @collects_when_back [:question_answered, :blocker_resolved]

  # Events that would start a turn through an `Agents.Waiting` path.
  #
  # `:resume` is deliberately absent: it has no path in `Wake.@waiting_path`,
  # because `Waiting`'s `@all` checks then held *every* event while a stale
  # resume offer sat open (nothing supersedes one a restart left open), and a
  # continuous idle QA was offered no `qa_complete` for 12+ minutes after
  # `ready_for_qa` passed. A resume is dispatched by `resume_held_task/2` and
  # redelivery, which call `Wake` directly, so it needs no waiting path -- and
  # an agent waiting on its provider is woken by it, like any other event.
  @waits [
    :work_offer,
    :teammate_question,
    :question_answered,
    :blocker_resolved,
    :nudge,
    :cadence,
    :teammate_stalled,
    :teammate_died
  ]

  @states for on <- [:on, :off, :retired, :stopped],
              continuous <- [true, false],
              waiting <- [false, true],
              in_turn <- [false, true],
              do: %{on: on, continuous: continuous, waiting: waiting, in_turn: in_turn}

  setup do
    scope = full_scope_fixture()

    agents =
      Map.new([:main, :product, :coding, :qa], fn role ->
        {:ok, agent} =
          AgentsRepository.create_agent(scope, %{
            provider: "anthropic",
            engine: :alloy,
            role: role,
            status: :running,
            working_copy: "/tmp/wake-#{role}",
            working_copy_id: scope.active_working_copy_id
          })

        AgentPresence.present(agent)

        {role, agent}
      end)

    %{scope: scope, agents: agents}
  end

  defp put_state(agent, state) do
    now = DateTime.utc_now()

    attrs = [
      status: status(state.on),
      off_at: stamp(state.on == :off, now),
      retired_at: stamp(state.on == :retired, now),
      continuous: state.continuous,
      provider_retry_at: stamp(state.waiting, DateTime.add(now, 3600)),
      turn_started_at: stamp(state.in_turn, now)
    ]

    Repo.update_all(from(a in Agent, where: a.id == ^agent.id), set: attrs)
    presence(agent, state.on)
    Repo.get!(Agent, agent.id)
  end

  # Stopped is a process that is not alive: not present.
  defp presence(agent, :stopped), do: AgentPresence.absent(agent)
  defp presence(agent, _on), do: AgentPresence.present(agent)

  defp status(:stopped), do: :stopped
  defp status(_on), do: :running

  defp stamp(true, at), do: at
  defp stamp(false, _at), do: nil

  defp expected(_role, _event, %{on: on}) when on in [:off, :retired], do: {:hold, on}
  defp expected(_role, _event, %{on: :stopped}), do: {:hold, :not_running}

  defp expected(role, event, state),
    do: relevant(event in @always or event in @relevant[role], event, state)

  defp relevant(false, _event, _state), do: {:hold, :not_relevant}
  defp relevant(true, :operator_message, _state), do: :wake

  defp relevant(true, event, %{continuous: false}) when event in @puts_to_work,
    do: {:hold, :not_continuous}

  defp relevant(true, event, %{continuous: false}) when event in @collects_when_back,
    do: :queue

  defp relevant(true, event, %{waiting: true, in_turn: false}) when event in @waits,
    do: {:hold, :provider_refused}

  defp relevant(true, _event, _state), do: :wake

  # The hold's agent and timestamp are not the point.
  defp shape({:hold, {kind, _detail}}), do: {:hold, kind}
  defp shape(decision), do: decision

  defp allowed(:wake, _state), do: :ok
  defp allowed(:queue, %{in_turn: true}), do: :ok
  defp allowed(:queue, _state), do: {:hold, :collects_when_back}
  defp allowed(hold, _state), do: hold

  test "every role, event and state decides as the table says", ctx do
    failures =
      for {role, agent} <- ctx.agents,
          state <- @states,
          agent = put_state(agent, state),
          event <- Wake.events(),
          want = expected(role, event, state),
          got = shape(Wake.decide(ctx.scope, agent, event)),
          allowed = shape(Wake.allow?(ctx.scope, agent, event)),
          got != want or allowed != allowed(want, state),
          do: {role, event, state, want: want, decided: got, allowed: allowed}

    assert failures == [], inspect(failures, pretty: true, limit: 20)
  end

  test "the event kinds are the ones the profiles and the table name" do
    named = @relevant |> Map.values() |> List.flatten() |> Kernel.++(@always) |> Enum.uniq()
    assert Enum.sort(named) == Enum.sort(Wake.events())
  end

  test "an off agent is held for every event, even a person's message", ctx do
    off =
      put_state(ctx.agents.coding, %{on: :off, continuous: true, waiting: false, in_turn: false})

    for event <- Wake.events() do
      assert {:hold, {:off, %Agent{}}} = Wake.allow?(ctx.scope, off, event)
    end
  end

  test "a non-continuous asker's answer waits for it, and joins a turn in flight", ctx do
    idle =
      put_state(ctx.agents.coding, %{on: :on, continuous: false, waiting: false, in_turn: false})

    assert {:hold, :collects_when_back} = Wake.allow?(ctx.scope, idle, :question_answered)

    busy = put_state(idle, %{on: :on, continuous: false, waiting: false, in_turn: true})
    assert :ok = Wake.allow?(ctx.scope, busy, :question_answered)
  end

  # Step 4b: a teammate stalling or dying, or asking, wakes main past its own
  # open question to the user (John).
  test "main's own open question does not hold a teammate's stall, death or question", ctx do
    main =
      put_state(ctx.agents.main, %{on: :on, continuous: true, waiting: false, in_turn: false})

    {:ok, _} =
      CodeMySpec.Notifications.create_agent_question_request(
        ctx.scope,
        main.id,
        %{
          "title" => "Which way",
          "holder" => "user",
          "questions" => [%{"question" => "Which way?", "options" => []}]
        },
        nil
      )

    assert {:hold, :question_pending} = Wake.allow?(ctx.scope, main, :nudge)

    for event <- [:teammate_stalled, :teammate_died, :teammate_question] do
      assert :ok = Wake.allow?(ctx.scope, main, event), inspect(event)
    end
  end

  test "a hold answers as the delivery paths always have" do
    agent = %Agent{}
    assert {:error, {:off, ^agent}} = Wake.to_error({:hold, {:off, agent}})
    assert {:error, {:retired, ^agent}} = Wake.to_error({:hold, {:retired, agent}})
    assert {:error, :not_running} = Wake.to_error({:hold, :not_running})
    assert {:error, {:held, :not_continuous}} = Wake.to_error({:hold, :not_continuous})
  end
end
