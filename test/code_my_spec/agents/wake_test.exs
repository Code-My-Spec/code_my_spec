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

  # Who hears what nobody else does. Everything else is relevant to everyone:
  # a person's message and the answers to the agent's own requests.
  @relevant %{
    main: [:work_offer, :nudge, :resume, :teammate_question, :findings, :issue_filed, :cadence],
    product: [:work_offer, :nudge, :resume],
    coding: [:work_offer, :nudge, :resume, :findings],
    qa: [:work_offer, :nudge, :resume]
  }
  @always [:operator_message, :own_reply, :question_answered, :blocker_resolved]

  # A non-continuous agent: woken, held, or handed it only inside a turn.
  @puts_to_work [:work_offer, :resume, :teammate_question]
  @collects_when_back [:question_answered, :blocker_resolved]

  # Events that would start a turn through an `Agents.Waiting` path.
  @waits [:work_offer, :teammate_question, :question_answered, :blocker_resolved, :resume, :nudge]

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
    Repo.get!(Agent, agent.id)
  end

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

  test "a hold answers as the delivery paths always have" do
    agent = %Agent{}
    assert {:error, {:off, ^agent}} = Wake.to_error({:hold, {:off, agent}})
    assert {:error, {:retired, ^agent}} = Wake.to_error({:hold, {:retired, agent}})
    assert {:error, :not_running} = Wake.to_error({:hold, :not_running})
    assert {:error, {:held, :not_continuous}} = Wake.to_error({:hold, :not_continuous})
  end
end
