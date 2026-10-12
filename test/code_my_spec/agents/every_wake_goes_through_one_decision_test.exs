defmodule CodeMySpec.Agents.EveryWakeGoesThroughOneDecisionTest do
  @moduledoc """
  a31f1cd6 step 4a: every path that reaches an agent asks `Agents.Wake`, naming
  its event. Observed through the decision's own announcement, so a path that
  stops asking — or asks about the wrong event — fails here by name.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import Ecto.Query

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.AnalysisReport
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.McpServers.Agents.Tools.MessageAgent
  alias CodeMySpec.McpServers.Devops.Starter
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpec.Notifications
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      Wake.telemetry_event(),
      fn _event, _measurements, meta, _config -> send(test_pid, {:wake, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: %{scope | active_working_copy_id: copy.id}, copy: copy}
  end

  defp agent(ctx, role, attrs \\ %{}) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        ctx.scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: role,
            status: :running,
            continuous: true,
            working_copy: "/tmp/wake-#{System.unique_integer([:positive])}",
            working_copy_id: ctx.copy.id
          },
          attrs
        )
      )

    AgentPresence.present(agent)

    agent
  end

  defp asked(%{id: id}, event) do
    assert_receive {:wake, %{agent_id: ^id, event: ^event, result: result}}, 1_000
    result
  end

  defp question(ctx, agent, holder \\ "user") do
    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        agent.id,
        %{
          "title" => "Which way",
          "holder" => holder,
          "questions" => [%{"question" => "Which way?", "options" => []}]
        },
        nil
      )

    request
  end

  describe "each path names its event" do
    test "a person at the page: dispatch_message as :operator_message", ctx do
      coding = agent(ctx, :coding)

      assert {:ok, :queued, _} =
               Agents.dispatch_message(ctx.scope, coding.id, "hello", :operator_message)

      assert asked(coding, :operator_message) == :ok
    end

    test "a provisioning run finishing: its starter hears it as :own_reply", ctx do
      coding = agent(ctx, :coding, %{continuous: false})

      :ok = Starter.tell({ctx.scope, coding.id, "setup"}, "setup finished")

      assert asked(coding, :own_reply) == :ok
      assert_receive {:agent_dispatch, _, _, "setup finished"}, 1_000
    end

    test "an analysis run: the asker as :own_reply, the rest as :findings by role", ctx do
      coding = agent(ctx, :coding)
      qa = agent(ctx, :qa)
      asker = agent(ctx, :product)

      AnalysisReport.deliver(ctx.scope, "spex", [%{severity: :error, source: "spex"}], asker.id)

      assert asked(asker, :own_reply) == :ok
      assert asked(coding, :findings) == :ok
      assert asked(qa, :findings) == {:hold, :not_relevant}

      for %{id: id} <- [asker, coding], do: assert_receive({:agent_dispatch, ^id, _, _}, 1_000)
    end

    test "a turn ending: the stop decision as :nudge, held for a non-continuous agent", ctx do
      coding = agent(ctx, :coding)
      StopDecision.deliver(ctx.scope, coding, [])
      assert asked(coding, :nudge) == :ok

      idle = agent(ctx, :coding, %{continuous: false})
      StopDecision.deliver(ctx.scope, idle, [])
      assert asked(idle, :nudge) == {:hold, :not_continuous}
    end

    test "the graph: a work offer as :work_offer", ctx do
      coding = agent(ctx, :coding)

      Work.request_turn_if_runnable(ctx.scope, coding, :graph_changed)

      assert asked(coding, :work_offer) == :ok
    end

    test "a teammate's question: main as :teammate_question", ctx do
      main = agent(ctx, :main)
      coding = agent(ctx, :coding)

      MainAgent.question_raised(ctx.scope, %{agent_id: coding.id})

      assert asked(main, :teammate_question) == :ok
    end

    # Criteria 2026 and 2120: a tap-out reaches main as an offer when it is
    # raised. It used to sit with the user until it aged a recovery interval.
    test "a teammate's tap-out: main is woken and offered it", ctx do
      main = agent(ctx, :main)
      coding = agent(ctx, :coding)
      frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: coding.id}}

      {:reply, reply, _} = TapOut.execute(%{reason: "blocked"}, frame)
      refute reply.isError

      assert asked(main, :teammate_question) == :ok

      assert CodeMySpec.Repo.exists?(
               from o in CodeMySpec.Agents.Offer,
                 where: o.agent_id == ^main.id and o.subject_type == "questions"
             )
    end

    test "a released blocker or a denied tap-out: offer_turn_with as the caller says", ctx do
      coding = agent(ctx, :coding, %{continuous: false})

      assert {:ok, :not_runnable} =
               Work.offer_turn_with(ctx.scope, coding, "carry on", :blocker_resolved)

      assert asked(coding, :blocker_resolved) == {:hold, :collects_when_back}
    end

    test "an answer, a decision, a re-offered turn: send_to_agent as the caller says", ctx do
      coding = agent(ctx, :coding)

      assert {:ok, :queued} = Agents.send_to_agent(coding.id, "approved", :own_reply)
      assert asked(coding, :own_reply) == :ok
    end
  end

  describe "behaviour" do
    test "an off agent is not woken by an event", ctx do
      coding = agent(ctx, :coding)
      {:ok, _} = Agents.turn_off_agent(ctx.scope, coding.id, by: "test", reason: "held")

      AnalysisReport.deliver(ctx.scope, "spex", [%{severity: :error, source: "spex"}], coding.id)

      assert {:hold, {:off, _}} = asked(coding, :own_reply)
      refute_received {:agent_dispatch, _, _, _}
    end

    test "a non-continuous asker's answer is kept for it, not a wake", ctx do
      coding = agent(ctx, :coding, %{continuous: false})
      request = question(ctx, coding)

      {:ok, _} = Notifications.answer_question_request(request.id, %{"Which way?" => "left"})

      assert asked(coding, :question_answered) == {:hold, :collects_when_back}
      refute_receive {:work_turn_requested, _, _, _}, 200
      refute_received {:agent_dispatch, _, _, _}
    end

    test "an answer that lands mid-turn joins the turn, task or no task", ctx do
      for continuous <- [true, false] do
        coding =
          agent(ctx, :coding, %{continuous: continuous, turn_started_at: DateTime.utc_now()})

        id = coding.id
        request = question(ctx, coding)

        {:ok, _} = Notifications.answer_question_request(request.id, %{"Which way?" => "left"})

        assert asked(coding, :question_answered) == :ok
        assert_receive {:agent_dispatch, ^id, _, text}, 1_000
        assert text =~ "A: left"
      end
    end
  end

  describe "c99aad08: main answering a teammate's question by message" do
    test "is told to answer it with answer_notification, and the message still goes", ctx do
      main = agent(ctx, :main)
      coding = agent(ctx, :coding)
      request = question(ctx, coding, "main_agent")

      frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: main.id}}

      {:reply, response, _frame} =
        MessageAgent.execute(%{agent_id: coding.id, message: "use postgres"}, frame)

      refute response.isError
      coding_id = coding.id
      assert_received {:agent_dispatch, ^coding_id, ref, "use postgres"}
      assert is_binary(ref)
      refute_received {:agent_message, _, _}

      text =
        response |> Response.to_protocol() |> Map.fetch!("content") |> Enum.map_join(& &1["text"])

      assert text =~ request.id
      assert text =~ "answer_notification"
    end

    test "says nothing extra when the agent has no question for main", ctx do
      main = agent(ctx, :main)
      coding = agent(ctx, :coding)
      frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: main.id}}

      {:reply, response, _frame} =
        MessageAgent.execute(%{agent_id: coding.id, message: "carry on"}, frame)

      refute response |> Response.to_protocol() |> inspect() =~ "answer_notification"
    end
  end
end
