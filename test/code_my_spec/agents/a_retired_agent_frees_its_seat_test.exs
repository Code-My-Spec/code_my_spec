defmodule CodeMySpec.Agents.ARetiredAgentFreesItsSeatTest do
  @moduledoc """
  Issue 39af5611, John: "Fire/delete/retire agent gets rid of it. Don't get the
  concepts mixed up."

  Off keeps the seat and can be turned back on. Retired frees the seat, can
  never be turned on, and is delivered nothing; its row and transcript stay.
  The staff button leaves an off role alone and fills a retired one, and
  offboarding retires.
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
  alias CodeMySpec.Conversations
  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.Agents.Tools.RetireAgent
  alias CodeMySpec.McpServers.Agents.Tools.TurnOnAgent
  alias CodeMySpec.Repo
  alias CodeMySpec.Staffing
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    root = "/workspace/retire-#{System.unique_integer([:positive])}"
    device = device_fixture(scope)

    # The project's main checkout, so the one under test is a feature copy:
    # coding agents never start on the main copy (`RoleProfile.home_copy`), and
    # a project's only checkout is its main one.
    {:ok, main} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "the main checkout",
        root: root <> "-main",
        device: device
      )

    {:ok, _main} = CodeMySpec.WorkingCopies.report_root(main, root <> "-main")

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        root: root,
        device: device
      )

    {:ok, copy} = CodeMySpec.WorkingCopies.report_root(copy, root)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        continuous: true,
        working_copy: root,
        working_copy_id: copy.id
      })

    %{scope: scope, copy: copy, agent: agent, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  defp retire(ctx) do
    {:ok, agent} = Agents.retire_agent(ctx.scope, ctx.agent.id, by: "Harness", reason: "done")
    agent
  end

  test "the retire_agent tool records who, when and why, and ends the process", ctx do
    {:reply, response, _} = RetireAgent.execute(%{agent_id: ctx.agent.id}, ctx.frame)

    refute response.isError, text(response)

    agent = Repo.get(Agent, ctx.agent.id)
    assert agent.status == :stopped
    assert Agent.retired?(agent)
    refute Agent.off?(agent)
    assert agent.retired_by == ctx.scope.user.email
    assert is_nil(agent.off_at), "retire must not borrow the off fields"
  end

  test "the seat is freed: a new agent starts there, and the old row stays", ctx do
    retired = retire(ctx)

    {:ok, fresh} =
      Agents.start_agent(ctx.scope, %{
        role: "coding",
        provider: "anthropic",
        working_copy_id: ctx.copy.id
      })

    refute fresh.id == retired.id
    assert Repo.get(Agent, retired.id), "the retired row is kept for its history"
    assert Agents.off_agents(ctx.scope) == []
    refute Enum.any?(MainAgent.list_agent_work(ctx.scope), &(&1.agent_id == retired.id))
  end

  test "an off agent that is then retired leaves the off list and frees its seat", ctx do
    {:ok, _} = Agents.turn_off_agent(ctx.scope, ctx.agent.id, by: "Harness")
    retire(ctx)

    assert Agents.off_agents(ctx.scope) == []
    assert MainAgent.list_off_agents(ctx.scope) == []

    assert %{started: [%Agent{}], off: []} =
             Agents.ensure_copy_agents(ctx.scope, ctx.copy, [:coding])
  end

  test "a retired agent cannot be turned on, by function or by tool", ctx do
    retire(ctx)

    assert {:error, {:retired, _}} = Agents.turn_on_agent(ctx.scope, ctx.agent.id)

    {:reply, response, _} = TurnOnAgent.execute(%{agent_id: ctx.agent.id}, ctx.frame)
    assert response.isError
    assert text(response) =~ "this agent is retired (retired by Harness at"
    assert Agent.retired?(Repo.get(Agent, ctx.agent.id))
  end

  test "a retired agent is delivered nothing and is not restarted", ctx do
    retire(ctx)

    assert {:error, {:retired, _}} = Agents.message_agent(ctx.scope, ctx.agent.id, "hi")
    assert {:error, {:retired, _}} = Agents.restart_agent(ctx.scope, ctx.agent.id)
    refute_received {:agent_message, _, _}
  end

  test "retiring on an unreachable machine still retires, frees the seat and says so", ctx do
    Application.put_env(:code_my_spec, :agent_transport, CodeMySpecTest.UnreachableMachine)

    assert {:ok, retired, {:unreachable, machine}} =
             Agents.retire_agent(ctx.scope, ctx.agent.id, by: "Harness")

    assert Agent.retired?(retired)
    assert is_binary(machine)

    {:reply, response, _} = RetireAgent.execute(%{agent_id: ctx.agent.id}, ctx.frame)
    refute response.isError, text(response)
    assert text(response) =~ "couldn't be reached, so its process may still be running"

    assert Agents.empty_seats([Repo.get(Agent, ctx.agent.id)], [:coding]) == [:coding]
  end

  test "the team-status list shows a retired agent's seat as empty", ctx do
    retire(ctx)

    refute Enum.any?(Agents.list_for_team_status(ctx.scope), &(&1.id == ctx.agent.id))
  end

  test "an off agent holds its seat; a retired one does not", ctx do
    {:ok, off} = Agents.turn_off_agent(ctx.scope, ctx.agent.id, by: "Harness")
    assert Agents.empty_seats([off], [:coding]) == []

    retire(ctx)
    assert Agents.empty_seats([Repo.get(Agent, ctx.agent.id)], [:coding]) == [:coding]
  end

  test "a person's answer to an off agent is recorded and answered, not delivered", ctx do
    {:ok, request} =
      CodeMySpec.Notifications.create_question_request(ctx.scope.user.id, %{
        "title" => "A question",
        "agent_id" => ctx.agent.id,
        "questions" => [%{"question" => "Which database?"}]
      })

    {:ok, _} = Agents.turn_off_agent(ctx.scope, ctx.agent.id, by: "Harness")

    assert {:ok, answered} =
             CodeMySpec.Notifications.answer_question_request(request.id, %{
               "Which database?" => "postgres"
             })

    assert answered.status == "answered"
    refute_received {:agent_dispatch, _, _, _}
    refute_received {:agent_message, _, _}

    # Even a direct send is refused at the gate; nothing reaches the machine.
    assert {:error, {:off, _}} =
             Agents.send_to_agent(ctx.agent.id, "use postgres", :question_answered)

    refute_received {:agent_dispatch, _, _, _}
  end

  test "offboarding retires the copy's agents", ctx do
    {:ok, counts} = Staffing.offboard(ctx.scope, ctx.copy)

    assert counts.agents_stopped == 1
    agent = Repo.get(Agent, ctx.agent.id)
    assert Agent.retired?(agent)
    assert agent.retired_reason == "its working copy was offboarded"
  end

  describe "the staff button" do
    test "leaves an off role alone and reports it, rather than failing", ctx do
      {:ok, _} =
        Agents.turn_off_agent(ctx.scope, ctx.agent.id, by: "Harness", reason: "held")

      report = Agents.ensure_copy_agents(ctx.scope, ctx.copy, [:coding])

      assert report.started == []
      assert report.failed == []
      assert [%Agent{id: id, off_by: "Harness", off_reason: "held"}] = report.off
      assert id == ctx.agent.id
    end

    test "fills a retired seat", ctx do
      retire(ctx)

      assert %{started: [%Agent{role: :coding}], failed: [], off: []} =
               Agents.ensure_copy_agents(ctx.scope, ctx.copy, [:coding])
    end
  end

  test "a work offer to an off agent writes nothing to its transcript", ctx do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        ctx.agent.id
      )

    {:ok, off} =
      AgentsRepository.update_agent(ctx.scope, ctx.agent, %{
        off_at: DateTime.utc_now(),
        off_by: "Harness"
      })

    assert {:error, {:off, _}} =
             Work.offer_turn_with(ctx.scope, off, "carry on", :blocker_resolved)

    assert Conversations.list_messages(conversation) == []
  end
end
