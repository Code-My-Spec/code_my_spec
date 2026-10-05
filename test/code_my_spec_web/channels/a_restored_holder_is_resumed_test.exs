defmodule CodeMySpecWeb.ARestoredHolderIsResumedTest do
  @moduledoc """
  A continuous agent a harness restart brings back holding a task gets a turn
  to finish it, and the turn names the task (0d3b800d).

  Driven through the harness's own restart exchange: `agents_to_restore`, then
  the `agents_present` report, which is what sweeps the copy.
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.DevicesFixtures
  import Phoenix.ChannelTest, except: [push: 3]

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
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

    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

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
      AgentsRepository.update_agent(
        scope,
        agent,
        Map.take(attrs, [:turn_started_at, :work_request_id, :work_requested_at])
      )

    agent
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

  test "a restored continuous agent holding a task is woken to resume it, by name", ctx do
    agent = holder(ctx.scope, %{turn_started_at: DateTime.add(DateTime.utc_now(), -60, :second)})
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

  test "a restored agent that is not continuous is not woken", ctx do
    idle = holder(ctx.scope, %{continuous: false, turn_started_at: DateTime.utc_now()})
    control = holder(ctx.scope, %{})

    restart(ctx.socket, [idle, control])

    control_id = control.id
    assert_receive {:work_turn_requested, ^control_id, _ref, _prompt}, 5_000

    idle_id = idle.id
    refute_received {:work_turn_requested, ^idle_id, _ref, _prompt}
    refute_received {:agent_dispatch, ^idle_id, _ref, _prompt}
    assert is_nil(Repo.get(Agent, idle_id).work_request_id)
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
      holder(ctx.scope, %{
        work_request_id: Ecto.UUID.generate(),
        work_requested_at: DateTime.add(DateTime.utc_now(), -30, :second)
      })

    restart(ctx.socket, [agent])

    agent_id = agent.id

    assert_receive {:work_turn_requested, ^agent_id, _ref, _prompt},
                   5_000,
                   """
                   A reservation stamped for the harness that died still fenced the
                   restored agent off, and the once-per-join sweep walked past it.
                   """
  end

  describe "a turn the restart discarded (5a977f41)" do
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

    test "is offered again with the message it was answering", ctx do
      agent = mid_turn(ctx.scope, %{}, "Rename the export columns, then run the suite.")

      restart(ctx.socket, [agent])

      agent_id = agent.id
      assert_receive {:work_turn_requested, ^agent_id, _ref, prompt}, 5_000

      assert prompt =~ "Rename the export columns, then run the suite.",
             "the restored agent's turn did not carry the message its discarded turn answered:\n#{prompt}"
    end

    test "reaches an agent out of the loop that was answering a person", ctx do
      agent = mid_turn(ctx.scope, %{continuous: false, role: "main"}, "Escalate f247c90f.")

      restart(ctx.socket, [agent])

      agent_id = agent.id
      assert_receive {:work_turn_requested, ^agent_id, _ref, prompt}, 5_000
      assert prompt =~ "Escalate f247c90f."
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
      assert_receive {:work_turn_requested, ^agent_id, _ref, prompt}, 5_000
      assert prompt =~ "Carry on with the task."
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
    end
  end
end
