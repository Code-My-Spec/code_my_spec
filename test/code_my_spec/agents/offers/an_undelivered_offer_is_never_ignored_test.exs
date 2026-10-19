defmodule CodeMySpec.Agents.Offers.AnUndeliveredOfferIsNeverIgnoredTest do
  @moduledoc """
  Criterion 1676: an offer that never reached the agent settles `undelivered`,
  never `ignored`, and a later turn end leaves it so.
  """
  use CodeMySpecSpex.Case, async: false

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.UnreachableMachine
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(Repo, {:shared, self()})
    CodeMySpecTest.AgentTransportRouter.route(context, UnreachableMachine)
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
            working_copy: "/tmp/undelivered-#{System.unique_integer([:positive])}",
            working_copy_id: scope.active_working_copy_id
          },
          attrs
        )
      )

    AgentPresence.present(agent)

    {:ok, _} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    on_exit(fn -> :persistent_term.erase({StopDecision, :continuing, agent.id}) end)
    agent
  end

  # The dispatches that run off the caller's process, finished.
  defp await_dispatches do
    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, 5_000 end)
  end

  defp end_turn(scope, agent) do
    {:ok, fresh} = AgentsRepository.fetch_agent(scope, agent.id)

    {:ok, _} =
      AgentsRepository.update_agent(scope, fresh, %{
        turn_started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    Agents.record_turn_event(
      scope,
      agent.id,
      ChannelClient.encode_turn_event(CodeMySpecSpex.Fixtures.mailbox_turn_end(scope, agent.id))
    )

    await_dispatches()
  end

  defp only(agent, kind) do
    assert [offer] = agent.id |> Offers.list_for_agent() |> Enum.filter(&(&1.kind == kind))
    offer
  end

  defp assert_undelivered_through_turn_end(scope, agent, kind) do
    offer = only(agent, kind)
    assert %{status: :undelivered, outcome_at: %DateTime{}} = offer

    end_turn(scope, agent)
    assert Repo.get!(Offer, offer.id).status == :undelivered
  end

  # An unreachable machine is a definite refusal (criterion 2042), not a
  # missed acknowledgement: the entry fails and the offer is undelivered.
  defp assert_undelivered_through_turn_end(scope, agent, kind) do
    offer = only(agent, kind)
    assert %{status: :undelivered} = offer
    assert [%{state: :failed}] = Agents.Mailbox.entries(scope, agent.id)
    end_turn(scope, agent)
    assert Repo.get!(Offer, offer.id).status == :undelivered
  end

  test "a work prompt whose turn request failed", ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)
    agent = agent(ctx.scope)

    assert {:error, :harness_not_connected} =
             Work.request_turn_if_runnable(ctx.scope, agent, :test)

    assert_undelivered_through_turn_end(ctx.scope, agent, :work)
  end

  test "a resume prompt whose turn request failed", ctx do
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

    offer = only(agent, :resume)
    assert offer.status == :undelivered
  end

  test "a check-in that could not be sent", ctx do
    {:ok, _} =
      CodeMySpec.WorkingCopies.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    main = agent(ctx.scope, %{role: "main"})

    assert {:error, :harness_not_connected} =
             Work.request_cadence_turn(ctx.scope, main, fn _work? -> "Check-in." end,
               attention?: true
             )

    assert_undelivered_through_turn_end(ctx.scope, main, :check_in)
  end

  test "a notice turn whose request failed", ctx do
    agent = agent(ctx.scope)

    assert {:error, :harness_not_connected} =
             Work.offer_turn_with(ctx.scope, agent, "The answer.", :question_answered, {
               "question",
               "q-1"
             })

    assert_undelivered_through_turn_end(ctx.scope, agent, :answer)
  end

  test "a notice recorded for a busy agent's next turn counts as delivered", ctx do
    agent = agent(ctx.scope)

    {:ok, busy} =
      AgentsRepository.update_agent(ctx.scope, agent, %{turn_started_at: DateTime.utc_now()})

    :ok =
      Work.wake_with_notice(ctx.scope, busy, "Unblocked.", :blocker_resolved, {"blocker", "b"})

    assert only(agent, :unblocked).status == :open
  end

  test "a notice whose turn failed is undelivered, and its fallback stands open", ctx do
    agent = agent(ctx.scope)

    :ok =
      Work.wake_with_notice(ctx.scope, agent, "Unblocked.", :blocker_resolved, {"blocker", "b"})

    assert [%{status: :undelivered}, %{status: :open}] = Offers.list_for_agent(agent.id)
  end

  describe "send_to_agent" do
    test "a dispatch that errors", ctx do
      agent = agent(ctx.scope)

      assert {:error, :harness_not_connected} =
               Agents.send_to_agent(agent.id, "A: left", :question_answered,
                 offer: {:answer, {"question", "q-1"}}
               )

      assert_undelivered_through_turn_end(ctx.scope, agent, :answer)
    end

    test "a send Wake refuses", ctx do
      agent = agent(ctx.scope)

      {:ok, _} =
        AgentsRepository.update_agent(ctx.scope, agent, %{
          off_at: DateTime.utc_now(),
          off_by: "Harness",
          off_reason: "held"
        })

      assert {:error, {:off, %Agent{}}} =
               Agents.send_to_agent(agent.id, "A: left", :question_answered,
                 offer: {:answer, {"question", "q-1"}}
               )

      assert only(agent, :answer).status == :undelivered
    end

    test "a failed turn's retry that could not be sent", ctx do
      agent = agent(ctx.scope, %{role: "main", continuous: false})
      Agents.record_turn_event(ctx.scope, agent.id, %{"kind" => "turn_started"})

      Agents.record_turn_event(ctx.scope, agent.id, %{
        "kind" => "turn_failed",
        "text" => "Claude Code returned tool_use without any tool calls"
      })

      await_dispatches()
      assert_undelivered_through_turn_end(ctx.scope, agent, :retry)
    end
  end

  test "a turn-end menu whose dispatch failed", ctx do
    agent = agent(ctx.scope, %{role: "qa"})

    task = %CodeMySpec.Agents.Agent.Task{
      id: Ecto.UUID.generate(),
      status: :active,
      requirement_name: "qa_complete",
      started_at: DateTime.utc_now()
    }

    :ok = StopDecision.deliver(ctx.scope, %{agent | tasks: [task]}, [])
    await_dispatches()

    assert_undelivered_through_turn_end(ctx.scope, agent, :menu)
  end

  test "an undelivered offer does not count toward the next attempt", ctx do
    agent = agent(ctx.scope)
    subject = {"question", "q-1"}

    {:error, _} = Work.offer_turn_with(ctx.scope, agent, "A.", :question_answered, subject)
    offer = Offers.record(nil, agent, :answer, subject)

    assert offer.attempt == 1
  end
end
