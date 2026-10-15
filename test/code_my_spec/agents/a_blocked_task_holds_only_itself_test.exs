defmodule CodeMySpec.Agents.ABlockedTaskHoldsOnlyItselfTest do
  @moduledoc """
  Story 1080, criteria 1757-1759: an agent's own question or task tap-out blocks
  only that task. Product is offered other work while it waits; an answered task
  comes back as an unblocked offer once the agent holds no active task — never
  as a second active one; and an agent holding only blocked work beside work it
  could claim is stalled.
  """

  use CodeMySpecSpex.Case, async: true

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Waiting
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.MainAgent.AgentWorkMapper
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.TaskOwner
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    :ok = Fixtures.install_recording_agent_transport(ctx)
    ctx = FullSatisfactionFixtures.apply(ctx)

    {:ok, _} =
      CodeMySpec.WorkingCopies.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    {:ok, _issue} =
      Issues.create_issue(ctx.scope, %{
        title: "the export button does nothing",
        description: "twice",
        severity: :medium
      })

    :ok = GraphWatcher.settle(ctx.scope)

    product = Fixtures.running_agent(ctx.scope, role: "product", continuous: true)
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: product.id}}
    Map.merge(ctx, %{product: product, frame: frame})
  end

  describe "product's own question (1757)" do
    setup ctx do
      product =
        ctx.product
        |> Agent.add_task(%{
          status: :active,
          requirement_name: "questions_answered",
          started_at: DateTime.utc_now()
        })
        |> Repo.update!()

      _question = ask(ctx.scope, product)
      %{product: Repo.get!(Agent, product.id)}
    end

    test "blocks only that task; triage is offered and startable", ctx do
      assert [%{status: :blocked, requirement_name: "questions_answered"}] = ctx.product.tasks
      assert Waiting.reason(ctx.scope, ctx.product, :offer) == nil

      assert {:ok, ref} = Work.request_turn_if_runnable(ctx.scope, ctx.product, :test)
      assert is_binary(ref)

      {:reply, next, _} = GetNextRequirement.execute(%{}, ctx.frame)
      assert response_text(next) =~ "requirement_name=`issues_triaged`"

      assert {:ok, started} = start_triage(ctx)
      refute started.isError, response_text(started)
    end
  end

  describe "an answered task while another is active (1758)" do
    setup ctx do
      assert {:ok, started} = start_triage(ctx)
      refute started.isError, response_text(started)
      question = ask(ctx.scope, Repo.get!(Agent, ctx.product.id))

      product =
        Agent
        |> Repo.get!(ctx.product.id)
        |> Agent.add_task(%{
          status: :active,
          requirement_name: "personas_complete",
          started_at: DateTime.utc_now()
        })
        |> Repo.update!()

      [blocked] = Enum.filter(product.tasks, &(&1.status == :blocked))
      %{product: product, question: question, blocked: blocked}
    end

    test "is not offered, and is never resumed beside the active task", ctx do
      product_id = ctx.product.id
      {:ok, _} = Notifications.answer_question_request(ctx.question.id, %{"Which?" => "A"})

      refute_receive {:work_turn_requested, ^product_id, _ref, _prompt}, 300

      product = Repo.get!(Agent, product_id)

      assert %{status: :blocked, blocker_resolved_at: %DateTime{}} =
               Agent.find_task(product, ctx.blocked.id)

      assert Enum.any?(
               Fixtures.messages_to_agent(ctx.scope, product_id),
               &(&1 =~ "Finish your active task first")
             )

      {:reply, refused, _} = start_triage!(ctx)
      assert refused.isError
      assert response_text(refused) =~ "beside your active task"
      assert [_one] = active_tasks(product_id)
    end

    test "is offered back as an unblocked offer once the active task is done", ctx do
      product_id = ctx.product.id
      {:ok, _} = Notifications.answer_question_request(ctx.question.id, %{"Which?" => "A"})

      active = Agent.active_task(ctx.product)
      {:ok, product} = TaskOwner.complete_task(ctx.scope, ctx.product, active.id)

      assert {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, product, :test)
      assert_receive {:work_turn_requested, ^product_id, _ref, prompt}, 2_000
      assert prompt =~ "resume task #{ctx.blocked.id}"

      assert [offer] = Offers.list(ctx.scope, agent_id: product_id, kind: :unblocked)
      assert {offer.subject_type, offer.subject_key} == {"task", ctx.blocked.id}

      {:reply, resumed, _} = start_triage!(ctx)
      refute resumed.isError, response_text(resumed)
      assert [%{id: id}] = active_tasks(product_id)
      assert id == ctx.blocked.id
    end

    test "a released task ignored three times is not offered again", ctx do
      product_id = ctx.product.id
      {:ok, _} = Notifications.answer_question_request(ctx.question.id, %{"Which?" => "A"})

      active = Agent.active_task(ctx.product)
      {:ok, product} = TaskOwner.complete_task(ctx.scope, ctx.product, active.id)

      # What a coder that would not resume it left behind on 2026-10-06: the
      # offer ignored after every turn, 570 times in half an hour.
      for attempt <- 1..Offers.held_after() do
        %Offer{}
        |> Offer.changeset(%{
          agent_id: product_id,
          kind: :unblocked,
          subject_type: "task",
          subject_key: ctx.blocked.id,
          attempt: attempt,
          status: :ignored,
          template_version: "unblocked/2"
        })
        |> Repo.insert!()
      end

      _ = Work.request_turn_if_runnable(ctx.scope, product, :test)
      :ok = Fixtures.drain_background_work()

      resumes =
        for prompt <- turn_prompts(product_id),
            prompt =~ "resume task #{ctx.blocked.id}",
            do: prompt

      assert resumes == [], "a released task ignored three times was offered again"
    end

    test "a released task offered back a second time says why again", ctx do
      product_id = ctx.product.id
      {:ok, _} = Notifications.answer_question_request(ctx.question.id, %{"Which?" => "A"})

      active = Agent.active_task(ctx.product)
      {:ok, product} = TaskOwner.complete_task(ctx.scope, ctx.product, active.id)

      # The offer the last turn took nothing of: `unblocked`'s first rung is
      # `:remind`, so the next offer of this task carries it (criterion 2057).
      %Offer{}
      |> Offer.changeset(%{
        agent_id: product_id,
        kind: :unblocked,
        subject_type: "task",
        subject_key: ctx.blocked.id,
        attempt: 1,
        status: :ignored,
        template_version: "unblocked/2"
      })
      |> Repo.insert!()

      assert {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, product, :test)
      :ok = Fixtures.drain_background_work()

      assert [prompt] = turn_prompts(product_id)
      assert prompt =~ "resume task #{ctx.blocked.id}"
      assert prompt =~ "You were told this last turn and did not take it"
      assert prompt =~ "`reject_offer` with your reason so main can reassign it"
    end

    test "mid-turn, the answer is the one message, naming what to do with the task", ctx do
      product_id = ctx.product.id
      before = Fixtures.messages_to_agent(ctx.scope, product_id)
      :ok = Fixtures.start_turn(ctx.scope, product_id)

      {:ok, _} = Notifications.answer_question_request(ctx.question.id, %{"Which?" => "A"})
      await_dispatches()

      assert [answer] = Fixtures.messages_to_agent(ctx.scope, product_id) -- before
      assert answer =~ "The user answered your question"
      assert answer =~ "Finish your active task first; task #{ctx.blocked.id}"
    end
  end

  test "released issue task names complete resume arguments", ctx do
    issue_id = Ecto.UUID.generate()

    agent =
      ctx.product
      |> Agent.add_task(%{
        status: :blocked,
        requirement_name: "fix_issue",
        issue_id: issue_id,
        blocker_type: :question,
        blocker_id: Ecto.UUID.generate(),
        blocked_at: now(),
        blocker_resolved_at: now()
      })
      |> Repo.update!()

    [task] = agent.tasks
    Work.wake_released(ctx.scope, agent, [task], "Resolved")
    :ok = Fixtures.drain_background_work()
    messages = Fixtures.messages_to_agent(ctx.scope, agent.id)

    assert Enum.any?(messages, fn text ->
             text =~ "requirement_name: \"fix_issue\"" and
               text =~ "entity_type: \"issue\"" and text =~ issue_id
           end)
  end

  test "a delayed release does not announce an obsolete blocker cycle", ctx do
    agent =
      ctx.product
      |> Agent.add_task(%{
        status: :blocked,
        requirement_name: "fix_issue",
        issue_id: Ecto.UUID.generate(),
        blocker_type: :question,
        blocker_id: Ecto.UUID.generate(),
        blocked_at: now(),
        blocker_resolved_at: now()
      })
      |> Repo.update!()

    [previous] = agent.tasks

    current =
      agent
      |> Agent.update_task(previous.id, %{
        blocker_id: Ecto.UUID.generate(),
        blocked_at: DateTime.add(now(), 1, :second),
        blocker_resolved_at: nil
      })
      |> Repo.update!()

    before = Fixtures.messages_to_agent(ctx.scope, agent.id)
    Work.wake_released(ctx.scope, agent, [previous], "OBSOLETE_RELEASE")
    :ok = Fixtures.drain_background_work()
    messages = Fixtures.messages_to_agent(ctx.scope, agent.id) -- before
    refute Enum.any?(messages, &(&1 =~ "OBSOLETE_RELEASE"))

    assert TaskOwner.find_task(Repo.get!(Agent, current.id), previous.id).blocker_id ==
             TaskOwner.find_task(current, previous.id).blocker_id
  end

  describe "pending tap-outs on two tasks (1759)" do
    setup ctx do
      product =
        Enum.reduce(["questions_answered", "personas_complete"], ctx.product, fn name, agent ->
          agent
          |> Agent.add_task(%{status: :active, requirement_name: name, started_at: now()})
          |> Repo.update!()
          |> tap_out_active(ctx.scope)
        end)

      %{product: product}
    end

    test "each is read by its task, and neither holds the agent", ctx do
      [first, second] = ctx.product.tasks

      for task <- [first, second] do
        assert %{task_id: task_id} =
                 Notifications.get_pending_tap_out_request(ctx.product.id, task.id)

        assert task_id == task.id
      end

      assert Notifications.get_pending_tap_out_request(ctx.product.id, nil) == nil

      {:ok, again} =
        Notifications.request_agent_tap_out(ctx.scope, ctx.product.id, first.id, "again")

      assert again.id == Notifications.get_pending_tap_out_request(ctx.product.id, first.id).id

      refute Waiting.awaiting_tap_out?(ctx.product)
      assert Waiting.reason(ctx.scope, ctx.product, :offer) == nil
      assert [%{tapped_out?: false}] = product_work(ctx)
    end

    test "a task-less one beside them still holds the agent", ctx do
      {:ok, whole} = Notifications.request_agent_tap_out(ctx.scope, ctx.product.id, nil, "stop")

      assert Notifications.get_pending_tap_out_request(ctx.product.id, nil).id == whole.id
      assert Waiting.reason(ctx.scope, ctx.product, :offer) == :tap_out
      assert [%{tapped_out?: true}] = product_work(ctx)
    end
  end

  describe "an agent holding only blocked work" do
    setup ctx do
      product =
        ctx.product
        |> Agent.add_task(%{
          status: :active,
          requirement_name: "questions_answered",
          started_at: now()
        })
        |> Repo.update!()

      _question = ask(ctx.scope, product)
      %{product: Repo.get!(Agent, product.id)}
    end

    test "is stalled beside work it could claim, and its blocked task is still shown", ctx do
      assert [entry] = product_work(ctx)
      assert %{task_status: :blocked, task_name: "questions_answered", idle?: false} = entry
      assert Digest.stalled(%Digest{work: [entry]}) == [entry]

      listing = AgentWorkMapper.text([entry])
      assert listing =~ "questions_answered [blocked]"
      assert listing =~ "STALLED: only blocked work in hand"
    end

    test "is not stalled while a task-less tap-out holds it", ctx do
      {:ok, _} = Notifications.request_agent_tap_out(ctx.scope, ctx.product.id, nil, "stop")

      assert [entry] = product_work(ctx)
      assert %{task_status: :blocked, tapped_out?: true} = entry
      assert Digest.stalled(%Digest{work: [entry]}) == []
    end
  end

  defp ask(scope, agent) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        agent.id,
        %{
          "title" => "Which approach?",
          "questions" => [%{"question" => "Which?", "options" => [%{"label" => "A"}]}]
        },
        :active
      )

    request
  end

  defp start_triage(ctx) do
    {:reply, response, _} = start_triage!(ctx)
    {:ok, response}
  end

  defp start_triage!(ctx) do
    StartTask.execute(
      %{
        requirement_name: "issues_triaged",
        entity_type: "project",
        entity_id: to_string(ctx.scope.active_project_id)
      },
      ctx.frame
    )
  end

  defp tap_out_active(agent, scope) do
    {:ok, _} =
      Notifications.request_agent_tap_out(scope, agent.id, Agent.active_task(agent).id, "stuck")

    Repo.get!(Agent, agent.id)
  end

  defp product_work(ctx),
    do: ctx.scope |> MainAgent.list_agent_work() |> Enum.filter(&(&1.agent_id == ctx.product.id))

  defp await_dispatches do
    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, 5_000 end)
  end

  defp now, do: DateTime.utc_now()

  defp active_tasks(agent_id),
    do: Agent |> Repo.get!(agent_id) |> Map.get(:tasks) |> Enum.filter(&(&1.status == :active))

  defp turn_prompts(agent_id) do
    receive do
      {:work_turn_requested, ^agent_id, _ref, prompt} -> [prompt | turn_prompts(agent_id)]
    after
      0 -> []
    end
  end
end
