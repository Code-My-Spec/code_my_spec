defmodule CodeMySpecWeb.ARestoredHolderIsResumedTest do
  @moduledoc """
  An agent a harness restart caught mid-turn carries that turn on; a
  continuous agent it brings back idle but holding a task gets a turn to
  finish it, and the turn names the task (0d3b800d).

  Driven through the harness's own restart exchange: `agents_to_restore`, then
  the `agents_present` report, which is what sweeps the copy.
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.DevicesFixtures
  import Ecto.Query
  import Phoenix.ChannelTest, except: [push: 3]

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    Sandbox.mode(Repo, {:shared, self()})

    RecordingAgentTransport.listen(ctx)

    {:ok, _reply, socket} =
      UserSocket
      |> socket("restored-holder", %{scope: ctx.scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{ctx.scope.active_project_id}",
        %{
          "label" => "the harness that just restarted",
          "harness_id" => ctx.scope.active_working_copy_id,
          "device" => %{"id" => device_fixture(ctx.scope).id}
        }
      )

    Map.put(ctx, :socket, socket)
  end

  defp holder(scope, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        continuous: Map.get(attrs, :continuous, true),
        status: :running,
        working_copy: "/tmp/restored-holder-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, _conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    {:ok, agent} =
      agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "issues_triaged",
        project_id: scope.active_project_id,
        started_at: DateTime.add(DateTime.utc_now(), -120, :second)
      })
      |> Repo.update()

    {:ok, agent} =
      AgentsRepository.update_agent(scope, agent, Map.take(attrs, [:turn_started_at]))

    turn_requested(agent, attrs[:turn_requested_at])
    agent
  end

  # A turn handed to the old harness: an open offer stamped when it went.
  defp turn_requested(_agent, nil), do: :ok

  defp turn_requested(agent, at) do
    {:ok, offer} = Offers.dispatch(agent, :resume, {"task", "earlier"})

    Repo.update_all(from(o in Offer, where: o.id == ^offer.id), set: [turn_requested_at: at])
    :ok
  end

  defp restore(socket) do
    ref = Phoenix.ChannelTest.push(socket, "agents_to_restore", %{})
    assert_reply ref, :ok, %{"agents" => _agents}, 2_000
  end

  defp report_present(socket, agents) do
    ref =
      Phoenix.ChannelTest.push(socket, "agents_present", %{
        "agent_ids" => Enum.map(agents, & &1.id)
      })

    assert_reply ref, :ok, %{}, 2_000
  end

  defp restart(socket, agents) do
    restore(socket)
    report_present(socket, agents)
  end

  test "a restored agent caught mid-turn carries the turn on", ctx do
    agent = holder(ctx.scope, %{turn_started_at: DateTime.add(DateTime.utc_now(), -60, :second)})

    restart(ctx.socket, [agent])

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, prompt}, 5_000
    assert prompt =~ "Carry on from your last step"
  end

  test "a restored continuous agent left holding a task is woken to resume it, by name", ctx do
    agent = holder(ctx.scope, %{})
    task = Agent.active_task(agent)

    restart(ctx.socket, [agent])

    agent_id = agent.id
    assert_receive {:work_turn_requested, ^agent_id, _ref, prompt}, 5_000

    assert prompt =~ "issues_triaged" and prompt =~ task.id,
           """
           The restored agent was offered a turn that does not name the task it holds.

           It said "you still hold the task below" and nothing followed:
           #{prompt}
           """
  end

  test "a restored agent that is not continuous and was not mid-turn is not woken", ctx do
    idle = holder(ctx.scope, %{continuous: false})
    control = holder(ctx.scope, %{})

    restart(ctx.socket, [idle, control])

    control_id = control.id
    assert_receive {:work_turn_requested, ^control_id, _ref, _prompt}, 5_000

    idle_id = idle.id
    refute_received {:work_turn_requested, ^idle_id, _ref, _prompt}
    refute_received {:agent_dispatch, ^idle_id, _ref, _prompt}
    refute Offers.in_flight?(idle_id)
  end

  test "a turn that died mid-call leaves the restored agent free, not busy", ctx do
    agent = holder(ctx.scope, %{turn_started_at: DateTime.add(DateTime.utc_now(), -30, :second)})

    restore(ctx.socket)

    row = Repo.get(Agent, agent.id)

    assert is_nil(row.turn_started_at),
           "the restored agent still reads mid-turn since #{row.turn_started_at}, " <>
             "a turn owned by a process the restart killed"
  end

  test "a wake the old harness took but never started does not hold the agent out", ctx do
    agent =
      holder(ctx.scope, %{turn_requested_at: DateTime.add(DateTime.utc_now(), -30, :second)})

    restart(ctx.socket, [agent])

    agent_id = agent.id

    assert_receive {:work_turn_requested, ^agent_id, _ref, _prompt},
                   5_000,
                   """
                   A turn handed to the harness that died still fenced the
                   restored agent off, and the once-per-join sweep walked past it.
                   """
  end

  describe "a turn the restart cut (5a977f41)" do
    defp mid_turn(scope, attrs, said) do
      {:ok, agent} =
        AgentsRepository.create_agent(scope, %{
          provider: "anthropic",
          engine: :alloy,
          role: Map.get(attrs, :role, "coding"),
          continuous: Map.get(attrs, :continuous, true),
          status: :running,
          working_copy: "/tmp/discarded-#{System.unique_integer([:positive])}",
          working_copy_id: scope.active_working_copy_id
        })

      AgentPresence.present(agent)

      {:ok, conversation} =
        Conversations.find_or_create_agent_conversation(
          scope.active_account_id,
          scope.active_project_id,
          agent.id
        )

      {:ok, _message} = Conversations.add_message(conversation, :user, said, "user")

      {:ok, agent} =
        AgentsRepository.update_agent(
          scope,
          agent,
          Map.merge(
            %{turn_started_at: DateTime.utc_now()},
            Map.take(attrs, [:declined_offer_count, :declined_offer, :declined_offer_at])
          )
        )

      agent
    end

    test "carries on rather than being handed its message again", ctx do
      agent = mid_turn(ctx.scope, %{}, "Rename the export columns, then run the suite.")

      restart(ctx.socket, [agent])

      agent_id = agent.id
      assert_receive {:agent_dispatch, ^agent_id, _ref, prompt}, 5_000
      assert prompt =~ "Carry on from your last step"

      refute prompt =~ "Rename the export columns",
             "the message was delivered a second time; it is already in the conversation"
    end

    test "reaches an agent out of the loop that was answering a person", ctx do
      agent = mid_turn(ctx.scope, %{continuous: false, role: "main"}, "Escalate f247c90f.")

      restart(ctx.socket, [agent])

      agent_id = agent.id
      assert_receive {:agent_dispatch, ^agent_id, _ref, prompt}, 5_000
      assert prompt =~ "Carry on from your last step"
    end

    test "reaches an agent whose work offers are damped", ctx do
      agent =
        mid_turn(
          ctx.scope,
          %{
            declined_offer: "damped",
            declined_offer_count: 5,
            declined_offer_at: DateTime.utc_now()
          },
          "Carry on with the task."
        )

      restart(ctx.socket, [agent])

      agent_id = agent.id
      assert_receive {:agent_dispatch, ^agent_id, _ref, _prompt}, 5_000
    end

    test "an agent that was idle is not handed an old message", ctx do
      {:ok, agent} =
        AgentsRepository.create_agent(ctx.scope, %{
          provider: "anthropic",
          engine: :alloy,
          role: "coding",
          continuous: false,
          status: :running,
          working_copy: "/tmp/idle-#{System.unique_integer([:positive])}",
          working_copy_id: ctx.scope.active_working_copy_id
        })

      AgentPresence.present(agent)

      {:ok, conversation} =
        Conversations.find_or_create_agent_conversation(
          ctx.scope.active_account_id,
          ctx.scope.active_project_id,
          agent.id
        )

      {:ok, _} = Conversations.add_message(conversation, :user, "An old request.", "user")

      restart(ctx.socket, [agent])

      :ok = CodeMySpecSpex.Fixtures.drain_background_work()

      agent_id = agent.id
      refute_received {:work_turn_requested, ^agent_id, _ref, _prompt}
      refute_received {:agent_dispatch, ^agent_id, _ref, _prompt}
    end
  end
end
