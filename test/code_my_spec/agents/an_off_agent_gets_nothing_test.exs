defmodule CodeMySpec.Agents.AnOffAgentGetsNothingTest do
  @moduledoc """
  Issue 39af5611: the Harness session stopped metric_flow's coding agent to hold
  it until a fix landed, and the main agent restarted it at its next check-in.

  Off is a shutdown, not a note. An off agent is sent nothing and offered no
  work, no automatic restart reaches it, and every tool that would act on it
  refuses until somebody turns it on. Turning on is the only way back.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.Agents.Tools.MessageAgent
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpec.McpServers.Agents.Tools.TurnOffAgent
  alias CodeMySpec.McpServers.Agents.Tools.TurnOnAgent
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpec.Repo
  alias CodeMySpecTest.RecordingAgentTransport

  @reason "held until the spec-binding fix lands"

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    copy =
      copy
      |> Ecto.Changeset.change(root: "/workspace/off-#{System.unique_integer([:positive])}")
      |> Repo.update!()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        continuous: true,
        working_copy: "/tmp/off-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, copy: copy, agent: agent, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  defp off(ctx) do
    {:ok, agent} = Agents.turn_off_agent(ctx.scope, ctx.agent.id, by: "Harness", reason: @reason)
    agent
  end

  # An off agent whose machine could not be asked to end it: the process is up,
  # the intent is off. The gate has to hold here too.
  defp off_but_running(ctx) do
    {:ok, agent} =
      AgentsRepository.update_agent(ctx.scope, ctx.agent, %{
        off_at: DateTime.utc_now(),
        off_by: "Harness",
        off_reason: @reason
      })

    agent
  end

  @refusal ~r/this agent is off \(turned off by Harness at [^:]+:\d\d:\d\d[^)]*: held until the spec-binding fix lands\); turn it on first/

  describe "turning off" do
    test "the tool records who, when and why, and ends the process", ctx do
      {:reply, response, _} =
        TurnOffAgent.execute(%{agent_id: ctx.agent.id, reason: @reason}, ctx.frame)

      refute response.isError, text(response)

      agent = Repo.get(Agent, ctx.agent.id)
      assert agent.status == :stopped
      assert agent.off_by == ctx.scope.user.email
      assert agent.off_reason == @reason
      assert %DateTime{} = agent.off_at
    end

    test "a reason is optional", ctx do
      {:reply, response, _} = TurnOffAgent.execute(%{agent_id: ctx.agent.id}, ctx.frame)

      refute response.isError, text(response)
      assert Agent.off?(Repo.get(Agent, ctx.agent.id))
    end

    test "the dev tools' stop turns it off too", ctx do
      {:ok, agent} = Agents.turn_off_any_agent(ctx.agent.id)
      assert Agent.off?(agent)
      assert agent.off_by == "the dev tools"
    end
  end

  describe "an off agent is delivered nothing" do
    test "a message is refused and never reaches the machine", ctx do
      off_but_running(ctx)

      assert {:error, {:off, %Agent{}}} = Agents.message_agent(ctx.scope, ctx.agent.id, "hi")

      assert {:error, {:off, %Agent{}}} =
               Agents.dispatch_message(ctx.scope, ctx.agent.id, "hi", :operator_message)

      assert {:error, {:off, %Agent{}}} =
               Agents.send_to_agent(ctx.agent.id, "your answer", :question_answered)

      refute_received {:agent_message, _, _}
      refute_received {:agent_dispatch, _, _, _}
    end

    test "the message_agent tool says it is off and how to get it back", ctx do
      off_but_running(ctx)

      {:reply, response, _} =
        MessageAgent.execute(%{agent_id: ctx.agent.id, message: "hi"}, ctx.frame)

      assert response.isError
      assert text(response) =~ @refusal
    end

    test "a work offer is refused and never reaches the machine", ctx do
      agent = off_but_running(ctx)

      assert {:error, {:off, _}} =
               Work.offer_turn_with(ctx.scope, agent, "carry on", :blocker_resolved)

      refute_received {:work_turn_requested, _, _, _}
    end

    test "the same offer reaches an agent that is on", ctx do
      assert {:ok, ref} =
               Work.offer_turn_with(ctx.scope, ctx.agent, "carry on", :blocker_resolved)

      assert is_binary(ref)
      assert_received {:work_turn_requested, _, _, _}
    end
  end

  describe "nothing restarts an off agent" do
    test "a reaped agent that is off is not restarted on reconnect", ctx do
      off(ctx)

      {:ok, _} =
        AgentsRepository.update_agent(ctx.scope, Repo.get(Agent, ctx.agent.id), %{
          stopped_reason: :reaped
        })

      :ok = Agents.restart_reaped_agents(ctx.scope, ctx.copy.id)

      assert Repo.get(Agent, ctx.agent.id).status == :stopped
    end

    test "a reaped agent that is on still is", ctx do
      {:ok, _} =
        AgentsRepository.update_agent(ctx.scope, ctx.agent, %{
          status: :stopped,
          stopped_reason: :reaped
        })

      :ok = Agents.restart_reaped_agents(ctx.scope, ctx.copy.id)

      refute Repo.get(Agent, ctx.agent.id).status == :stopped
    end

    test "the main agent's restart_agent refuses it, naming who and why", ctx do
      off(ctx)

      {:reply, response, _} =
        RestartAgent.execute(%{agent_id: ctx.agent.id, reason: "it is stopped"}, ctx.frame)

      assert response.isError
      assert text(response) =~ @refusal
      assert Agent.off?(Repo.get(Agent, ctx.agent.id))
    end

    test "start_agent into its seat is refused and does not turn it on", ctx do
      off(ctx)

      {:reply, response, _} =
        StartAgent.execute(%{role: "coding", working_copy_id: ctx.copy.id}, ctx.frame)

      assert response.isError
      assert text(response) =~ @refusal
      assert [%Agent{id: id}] = Agents.off_agents(ctx.scope)
      assert id == ctx.agent.id
    end
  end

  describe "turning on" do
    test "the main agent's turn_on_agent starts it and clears the record", ctx do
      off(ctx)

      {:reply, response, _} = TurnOnAgent.execute(%{agent_id: ctx.agent.id}, ctx.frame)

      refute response.isError, text(response)

      agent = Repo.get(Agent, ctx.agent.id)
      refute agent.status == :stopped
      assert is_nil(agent.off_at) and is_nil(agent.off_by) and is_nil(agent.off_reason)
    end

    test "after turning on, messages reach it again", ctx do
      off(ctx)
      {:ok, _} = Agents.turn_on_agent(ctx.scope, ctx.agent.id)

      assert {:ok, _} = Agents.message_agent(ctx.scope, ctx.agent.id, "hi")
      id = ctx.agent.id
      assert_received {:agent_dispatch, ^id, ref, "hi"}
      assert is_binary(ref)
      refute_received {:agent_message, _, _}
    end
  end

  describe "an off agent whose machine could not end it" do
    test "stays findable as running, and is not restored or reported as working", ctx do
      off_but_running(ctx)

      assert Enum.any?(Agents.list_running(ctx.scope), &(&1.id == ctx.agent.id))
      refute Enum.any?(Agents.list_on_duty(ctx.scope), &(&1.id == ctx.agent.id))
      assert MainAgent.list_agent_work(ctx.scope) == []
    end

    test "is recorded stopped once its machine reports it gone", ctx do
      off_but_running(ctx)

      :ok = Agents.record_running_on_copy(ctx.scope, ctx.copy.id, [])

      agent = Repo.get(Agent, ctx.agent.id)
      assert agent.status == :stopped
      assert Agent.off?(agent)
    end
  end

  test "the main agent's view lists it as off", ctx do
    off(ctx)

    assert [%Agent{}] = MainAgent.list_off_agents(ctx.scope)
    assert MainAgent.list_agent_work(ctx.scope) == []
  end
end
