defmodule CodeMySpec.Agents.Offers.EveryNudgeIsRecordedAsAnOfferTest do
  @moduledoc """
  b75b0198 step 1: each nudge path writes an offer linked to the message it was
  recorded as, and sends exactly what it sent before.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.TaskOwner
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  @work_prompt "Eligible work is available. Call get_next_requirement to see it, " <>
                 "then claim it with start_task. No task has been selected or assigned for you."

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()
    :ok
  end

  defp agent(scope, attrs \\ %{}) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: "coding",
            continuous: true,
            status: :running,
            working_copy: "/tmp/offers-#{System.unique_integer([:positive])}",
            working_copy_id: scope.active_working_copy_id
          },
          attrs
        )
      )

    {:ok, _conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    agent
  end

  defp with_work(ctx) do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)
    ctx
  end

  defp linked_texts(offer) do
    Enum.map(offer.messages, &(Repo.get!(Message, &1.message_id) |> Message.text()))
  end

  defp end_reservation(scope, agent) do
    {:ok, fresh} = AgentsRepository.fetch_agent(scope, agent.id)

    {:ok, _} =
      AgentsRepository.update_agent(scope, fresh, %{work_request_id: nil, work_requested_at: nil})
  end

  describe "the work offer" do
    test "records a work offer on the head of its work, linked to the prompt it sent", ctx do
      ctx = with_work(ctx)
      agent = agent(ctx.scope)
      [head | _] = Work.claimable_work(ctx.scope, agent)

      assert {:ok, ref} = Work.request_turn_if_runnable(ctx.scope, agent, :test)
      id = agent.id
      assert_received {:work_turn_requested, ^id, ^ref, @work_prompt}

      assert [offer] = Offers.list_for_agent(agent.id)
      assert offer.kind == :work
      assert offer.status == :open
      assert offer.attempt == 1
      assert offer.template_version == "work/1"
      assert offer.subject_type == "requirement"
      assert offer.subject_key == "#{head.entity_type}:#{head.entity_id}:#{head.name}"
      assert offer.working_copy_id == ctx.scope.active_working_copy_id
      assert linked_texts(offer) == [@work_prompt]
    end

    test "a second offer of the same work supersedes the first", ctx do
      ctx = with_work(ctx)
      agent = agent(ctx.scope)

      {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, agent, :test)
      end_reservation(ctx.scope, agent)
      {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, agent, :test)

      assert [first, second] = Offers.list_for_agent(agent.id)
      assert first.status == :superseded
      assert first.outcome_at
      assert second.status == :open
      assert second.attempt == 2
    end

    test "a damped offer is neither sent nor recorded", ctx do
      ctx = with_work(ctx)
      agent = agent(ctx.scope)
      claimable = Work.claimable_work(ctx.scope, agent)

      {:ok, damped} =
        AgentsRepository.update_agent(ctx.scope, agent, %{
          declined_offer: Work.offer_fingerprint(ctx.scope, agent, claimable),
          declined_offer_at: DateTime.utc_now(),
          declined_offer_count: 5
        })

      assert {:ok, :offer_declined} = Work.request_turn_if_runnable(ctx.scope, damped, :test)
      refute_received {:work_turn_requested, _, _, _}
      assert Offers.list_for_agent(agent.id) == []
    end
  end

  test "the resume after a restart records a resume offer on the held task", ctx do
    agent = agent(ctx.scope)

    {:ok, held} =
      agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "bdd_specs_passing",
        started_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })
      |> Repo.update()

    :ok = Work.resume_held_tasks(ctx.scope, held.working_copy_id)

    id = agent.id
    assert_received {:work_turn_requested, ^id, _ref, prompt}
    assert prompt =~ "the harness restarted under it"

    task = Agent.active_task(held)
    assert [offer] = Offers.list_for_agent(agent.id)
    assert {offer.kind, offer.subject_type, offer.subject_key} == {:resume, "task", task.id}
    assert linked_texts(offer) == [prompt]
  end

  test "main's check-in turn records a check_in offer", ctx do
    {:ok, _} =
      CodeMySpec.WorkingCopies.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    main = agent(ctx.scope, %{role: "main"})

    assert {:ok, _ref} =
             Work.request_cadence_turn(ctx.scope, main, &"Check-in. Work offered: #{&1}")

    id = main.id
    assert_received {:work_turn_requested, ^id, _ref, "Check-in. Work offered: " <> _ = prompt}

    assert [offer] = Offers.list_for_agent(main.id)
    assert {offer.kind, offer.subject_type, offer.subject_key} == {:check_in, "cadence", nil}
    assert linked_texts(offer) == [prompt]
  end

  defp question(scope, agent, task_id) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        agent.id,
        %{
          "title" => "Which way",
          "questions" => [%{"question" => "Which way?", "options" => []}]
        },
        task_id
      )

    request
  end

  describe "an answered question" do
    test "an idle asker's answer wake records an answer offer on the question", ctx do
      agent = agent(ctx.scope)
      request = question(ctx.scope, agent, nil)

      {:ok, _} = Notifications.answer_question_request(request.id, %{"Which way?" => "left"})

      id = agent.id
      assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
      assert prompt =~ "A: left"
      assert String.ends_with?(prompt, @work_prompt)

      assert [offer] = Offers.list_for_agent(agent.id)

      assert {offer.kind, offer.subject_type, offer.subject_key} ==
               {:answer, "question", request.id}

      assert linked_texts(offer) == [prompt]
    end

    test "an answer delivered mid-turn records an answer offer", ctx do
      agent = agent(ctx.scope)

      {:ok, _} =
        AgentsRepository.update_agent(ctx.scope, agent, %{turn_started_at: DateTime.utc_now()})

      request = question(ctx.scope, agent, nil)

      {:ok, _} = Notifications.answer_question_request(request.id, %{"Which way?" => "right"})

      id = agent.id
      assert_receive {:agent_dispatch, ^id, _ref, message}, 2_000
      assert message =~ "A: right"

      assert [offer] = Offers.list_for_agent(agent.id)
      assert {offer.kind, offer.subject_key} == {:answer, request.id}
      assert linked_texts(offer) == [message]
    end

    test "a released task's blocker_resolved wake records an unblocked offer", ctx do
      agent = agent(ctx.scope)
      {:ok, agent} = TaskOwner.add_task(ctx.scope, agent, %{requirement_name: "story_promoted"})
      [task] = agent.tasks
      {:ok, agent} = TaskOwner.activate_task(ctx.scope, agent, task.id)
      request = question(ctx.scope, agent, task.id)

      {:ok, _} = Notifications.answer_question_request(request.id, %{"Which way?" => "up"})

      id = agent.id
      assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
      assert prompt =~ "Your blocker question #{request.id}"
      assert prompt =~ "resume task #{task.id}"

      assert [offer] = Offers.list_for_agent(agent.id)

      assert {offer.kind, offer.subject_type, offer.subject_key} ==
               {:unblocked, "task", task.id}

      assert linked_texts(offer) == [prompt]
    end
  end

  describe "a harness restart (f5699eb9)" do
    test "an idle agent's restart notice records a resume offer linked to it", ctx do
      agent = agent(ctx.scope)

      :ok = Agents.account_for_interrupted_turns(ctx.scope, [agent])

      assert [offer] = Offers.list_for_agent(agent.id)
      assert {offer.kind, offer.subject_type, offer.subject_key} == {:resume, "restart", nil}
      assert offer.template_version == "resume/1"
      assert [notice] = linked_texts(offer)
      assert notice =~ "The harness restarted. No turn of yours was interrupted"
    end

    test "a mid-turn agent's interrupted notice records a resume offer linked to it", ctx do
      agent = agent(ctx.scope)

      {:ok, mid_turn} =
        AgentsRepository.update_agent(ctx.scope, agent, %{turn_started_at: DateTime.utc_now()})

      :ok = Agents.account_for_interrupted_turns(ctx.scope, [mid_turn])

      assert [offer] = Offers.list_for_agent(agent.id)
      assert {offer.kind, offer.subject_type, offer.subject_key} == {:resume, "restart", nil}
      assert [notice] = linked_texts(offer)
      assert notice =~ "while you were part-way through a turn"
    end

    test "a second restart supersedes the first notice's offer", ctx do
      agent = agent(ctx.scope)

      :ok = Agents.account_for_interrupted_turns(ctx.scope, [agent])
      :ok = Agents.account_for_interrupted_turns(ctx.scope, [agent])

      assert [first, second] = Offers.list_for_agent(agent.id)
      assert first.status == :superseded
      assert second.status == :open
    end
  end

  describe "a failed turn" do
    @failure "Claude Code returned tool_use without any tool calls"

    test "its retry records a retry offer", ctx do
      agent = agent(ctx.scope, %{role: "main", continuous: false})
      Agents.record_turn_event(ctx.scope, agent.id, %{"kind" => "turn_started"})
      conversation = CodeMySpecSpex.Fixtures.agent_conversation(ctx.scope, agent)
      Conversations.add_message(conversation, :user, "Make me a help page.", "user")

      Agents.record_turn_event(ctx.scope, agent.id, %{"kind" => "turn_failed", "text" => @failure})

      id = agent.id
      assert_receive {:agent_dispatch, ^id, _ref, notice}, 2_000
      assert notice =~ @failure
      assert notice =~ "Make me a help page."

      assert [offer] = Offers.list_for_agent(agent.id)
      assert {offer.kind, offer.subject_type} == {:retry, "failed_turn"}
      assert linked_texts(offer) == [notice]
    end

    test "a failure on the retry is not re-sent and records no second offer", ctx do
      agent = agent(ctx.scope, %{role: "main", continuous: false})
      Agents.record_turn_event(ctx.scope, agent.id, %{"kind" => "turn_started"})
      conversation = CodeMySpecSpex.Fixtures.agent_conversation(ctx.scope, agent)
      Conversations.add_message(conversation, :user, "Make me a help page.", "user")
      fail = %{"kind" => "turn_failed", "text" => @failure}

      Agents.record_turn_event(ctx.scope, agent.id, fail)
      assert_receive {:agent_dispatch, _, _, _}, 2_000
      Agents.record_turn_event(ctx.scope, agent.id, fail)

      refute_receive {:agent_dispatch, _, _, _}, 300
      assert [%{kind: :retry}] = Offers.list_for_agent(agent.id)
    end
  end
end
