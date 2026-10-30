defmodule CodeMySpec.Agents.IssueWorkTest do
  @moduledoc """
  Story 1091's pairing resolves an issue only through a passing
  `Qa.IssueQaAttempts.submit/2`. A resolution recorded another way —
  `resolve_issue`/`dismiss_issue` called directly — must still stop
  `IssueWork` from re-offering qa_complete/fix_issue for it (011b1418).
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.IssueWork
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.AgentTasks.IssueFix
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Agents.Agent.Task
  alias CodeMySpec.Support.InMemoryExecutionContext
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  @copy "/issue-fix/copy"
  @head "7777777777777777777777777777777777777777"
  @head2 "8888888888888888888888888888888888888888"

  defp clean_shell(head \\ @head) do
    test = self()

    fn "git", args, opts ->
      send(test, {:git, Keyword.fetch!(opts, :cd), args})
      clean_answer(args, head)
    end
  end

  defp clean_answer(["status" | _], _head), do: {"", 0}
  defp clean_answer(["rev-parse", "--abbrev-ref", "HEAD"], _head), do: {"issue/x\n", 0}
  defp clean_answer(["rev-parse", "HEAD"], head), do: {head <> "\n", 0}
  defp clean_answer(["ls-files" | _], _head), do: {"", 0}
  defp clean_answer(args, _head), do: {"unscripted: git #{Enum.join(args, " ")}", 1}

  # A certifiable copy: a clean tree at a known HEAD, with every analyzer
  # already fresh there, so `IssueFix`'s certification passes on the first
  # call rather than starting runs (that path belongs to issue_fix_test.exs).
  defp certifiable_copy(scope) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "copy", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, @copy)
    :ok = HarnessRegistry.register_executor(copy.id, "copy-harness", @copy)
    {:ok, env} = InMemoryExecutionContext.create(shell: clean_shell())
    :ok = CodeMySpec.ExecutionContexts.unregister({:working_copy, copy.id})
    :ok = CodeMySpec.ExecutionContexts.register({:working_copy, copy.id}, env)
    scope = %{scope | active_working_copy_id: copy.id}
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)
    %{scope: scope, copy_id: copy.id}
  end

  # Rework lands at a new commit: a different HEAD from the shell, and fresh
  # analysis stamped there, so the second certification is a distinct pass
  # rather than a replay of the first.
  defp recertify_at(scope, copy_id, head) do
    {:ok, env} = InMemoryExecutionContext.create(shell: clean_shell(head))
    :ok = CodeMySpec.ExecutionContexts.unregister({:working_copy, copy_id})
    :ok = CodeMySpec.ExecutionContexts.register({:working_copy, copy_id}, env)
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: head)
  end

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope, %{status: :accepted})
    %{scope: scope, issue: issue}
  end

  defp agent(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: role,
        status: :running,
        working_copy_id: copy_id
      })

    AgentPresence.present(agent)

    agent
  end

  defp copy(scope) do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    copy.id
  end

  defp reload(agent), do: Repo.get!(Agents.Agent, agent.id)

  test "an issue task resumes after reusing its answered question", ctx do
    %{scope: scope, copy_id: copy_id} = certifiable_copy(ctx.scope)
    coding = agent(scope, :coding, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(scope, ctx.issue.id, copy_id)
    context = %{scope: scope, agent_id: coding.id}
    params = %{requirement_name: "fix_issue", entity_type: "issue", entity_id: ctx.issue.id}
    assert {:ok, _} = ToolLibrary.run("start_task", params, context)
    [task] = reload(coding).tasks

    attrs = %{
      "title" => "Implementation decision",
      "questions" => [%{"question" => "Which approach?", "options" => []}]
    }

    {:ok, question} =
      CodeMySpec.Notifications.create_agent_question_request(
        scope,
        coding.id,
        attrs,
        task.id
      )

    {:ok, _} =
      CodeMySpec.Notifications.answer_question_request(
        question.id,
        %{"Which approach?" => "Use the existing implementation"}
      )

    {:ok, reused} =
      CodeMySpec.Notifications.create_agent_question_request(
        scope,
        coding.id,
        attrs,
        task.id
      )

    assert reused.id == question.id
    assert reused.status == "answered"
    assert {:ok, _} = ToolLibrary.run("start_task", params, context)
    [resumed] = reload(coding).tasks
    assert resumed.id == task.id
    assert resumed.status == :active
  end

  test "evaluating a fix hands it to QA and refuses a second coding task", ctx do
    %{scope: scope, copy_id: copy_id} = certifiable_copy(ctx.scope)
    coding = agent(scope, :coding, copy_id)
    qa = agent(scope, :qa, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(scope, ctx.issue.id, copy_id)
    frame = %Frame{assigns: %{current_scope: scope, agent_id: coding.id}}
    params = %{requirement_name: "fix_issue", entity_type: "issue", entity_id: ctx.issue.id}

    started =
      ToolLibrary.run(
        "start_task",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, started)
    [task] = reload(coding).tasks

    evaluated =
      ToolLibrary.run(
        "evaluate_task",
        %{task_id: task.id},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, evaluated)
    assert [%{id: task_id, status: :completed}] = reload(coding).tasks
    assert task_id == task.id
    assert Issues.get_issue(scope, ctx.issue.id).awaiting_role == :qa
    assert Issues.get_issue(scope, ctx.issue.id).qa_ready_commit == @head
    assert %{status: :blocked, actionable: []} = IssueWork.execution(scope, reload(coding))

    assert [%{name: "qa_complete", entity_id: issue_id}] =
             IssueWork.execution(scope, reload(qa)).actionable

    assert issue_id == ctx.issue.id

    duplicate =
      ToolLibrary.run(
        "start_task",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:error, _}, duplicate)
    assert [%{id: ^task_id, status: :completed}] = reload(coding).tasks
  end

  # A failed attempt must not leave QA re-offered the same commit it just
  # failed, and must not leave the coder blocked either -- the two halves of
  # 4100468a. `send_back_to_coder/2` clears `qa_ready_commit` and flips
  # `awaiting_role` to `:coding` inside the same transaction as the attempt,
  # so this exercises the full tool path rather than the domain function
  # directly: a regression here would be a graph-level discrepancy, not a
  # unit-level one.
  test "a failed QA attempt sends the fix back to the coder, not qa_complete again at the same commit; a new certified commit offers QA again (4100468a)",
       ctx do
    %{scope: scope, copy_id: copy_id} = certifiable_copy(ctx.scope)
    coding = agent(scope, :coding, copy_id)
    qa = agent(scope, :qa, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(scope, ctx.issue.id, copy_id)

    coding_frame = %Frame{assigns: %{current_scope: scope, agent_id: coding.id}}
    fix_params = %{requirement_name: "fix_issue", entity_type: "issue", entity_id: ctx.issue.id}

    started =
      ToolLibrary.run(
        "start_task",
        fix_params,
        Map.put(coding_frame.assigns, :scope, coding_frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, started)
    [fix_task] = reload(coding).tasks

    evaluated =
      ToolLibrary.run(
        "evaluate_task",
        %{task_id: fix_task.id},
        Map.put(coding_frame.assigns, :scope, coding_frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, evaluated)

    assert Issues.get_issue(scope, ctx.issue.id).awaiting_role == :qa
    assert Issues.get_issue(scope, ctx.issue.id).qa_ready_commit == @head

    qa_frame = %Frame{assigns: %{current_scope: scope, agent_id: qa.id}}
    qa_params = %{requirement_name: "qa_complete", entity_type: "issue", entity_id: ctx.issue.id}

    started_qa =
      ToolLibrary.run(
        "start_task",
        qa_params,
        Map.put(qa_frame.assigns, :scope, qa_frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, started_qa)
    [qa_task] = reload(qa).tasks

    submitted =
      ToolLibrary.run(
        "submit_issue_qa_result",
        %{
          issue_id: ctx.issue.id,
          task_id: qa_task.id,
          status: "fail",
          issue_ids: [ctx.issue.id],
          scenarios: [%{name: "Delivery", status: "fail", observation: "Still broken"}]
        },
        Map.put(qa_frame.assigns, :scope, qa_frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, submitted)

    issue = Issues.get_issue(scope, ctx.issue.id)
    assert issue.awaiting_role == :coding
    refute issue.qa_ready_commit

    # Same commit: QA is not offered qa_complete again -- the fix is the
    # coder's turn, not QA's, until a new commit is certified.
    assert %{status: :blocked, actionable: []} = IssueWork.execution(scope, reload(qa))

    assert [%{name: "fix_issue", entity_id: issue_id}] =
             IssueWork.execution(scope, reload(coding)).actionable

    assert issue_id == ctx.issue.id

    # The coder reworks it and certifies at a new commit.
    recertify_at(scope, copy_id, @head2)

    started2 =
      ToolLibrary.run(
        "start_task",
        fix_params,
        Map.put(coding_frame.assigns, :scope, coding_frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, started2)
    rework_task = Enum.find(reload(coding).tasks, &(&1.status != :completed))

    evaluated2 =
      ToolLibrary.run(
        "evaluate_task",
        %{task_id: rework_task.id},
        Map.put(coding_frame.assigns, :scope, coding_frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, evaluated2)

    issue = Issues.get_issue(scope, ctx.issue.id)
    assert issue.awaiting_role == :qa
    assert issue.qa_ready_commit == @head2

    assert [%{name: "qa_complete", entity_id: issue_id2}] =
             IssueWork.execution(scope, reload(qa)).actionable

    assert issue_id2 == ctx.issue.id
  end

  test "a missing issue cannot produce a passing fix evaluation", ctx do
    task = %Task{issue_id: Ecto.UUID.generate()}
    assert {:error, message} = IssueFix.evaluate(ctx.scope, task)
    assert message =~ "no longer exists"
  end

  test "an assigned unlinked issue cannot resolve with an unlanded fix", ctx do
    assert_unlanded_resolution_refused(ctx, false)
  end

  test "an assigned story issue cannot resolve with an unlanded fix", ctx do
    assert_unlanded_resolution_refused(ctx, true)
  end

  defp assert_unlanded_resolution_refused(ctx, story_linked?) do
    copy_id = copy(ctx.scope)
    coder = agent(ctx.scope, :coding, copy_id)

    issue = issue_for_resolution_test(ctx, story_linked?)

    {:ok, assigned} = Agents.assign_issue_to_working_copy(ctx.scope, issue.id, copy_id)

    {:ok, owner} =
      TaskOwner.add_task(ctx.scope, reload(coder), %{
        status: :active,
        requirement_name: "fix_issue",
        issue_id: issue.id
      })

    task = Enum.find(owner.tasks, &(&1.requirement_name == "fix_issue"))

    # The original struct predates assignment, exactly the stale caller that
    # previously bypassed a guard placed only at the resolve_issue tool.
    assert {:error, :fix_not_landed_on_main_use_evaluate_task_then_promote_issue} =
             Issues.resolve_issue(ctx.scope, issue, "Committed on the copy")

    assert {:error, :fix_not_landed_on_main_use_evaluate_task_then_promote_issue} =
             Issues.resolve_issue(ctx.scope, assigned, "Committed on the copy")

    assert %{status: :accepted, landed_commit: nil} = Issues.get_issue(ctx.scope, issue.id)
    assert %{status: :active} = TaskOwner.find_task(reload(coder), task.id)
  end

  defp issue_for_resolution_test(ctx, false), do: ctx.issue

  defp issue_for_resolution_test(ctx, true) do
    story = story_fixture(ctx.scope)
    {:ok, linked} = Issues.update_issue(ctx.scope, ctx.issue, %{story_id: story.id})
    linked
  end

  test "resolving an issue supersedes its promotion offer without affecting other work", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    {:ok, assigned} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, promoting} = Issues.set_awaiting_role(ctx.scope, assigned, :promote)
    coding = reload(coding)

    assert [%{name: "promote_issue"}] = Work.claimable_work(ctx.scope, coding)

    offered =
      CodeMySpec.Agents.Offers.record(
        nil,
        coding,
        :work,
        {"requirement", "issue:#{promoting.id}:promote_issue"}
      )

    other =
      CodeMySpec.Agents.Offers.record(
        nil,
        coding,
        :work,
        {"requirement", "issue:#{Ecto.UUID.generate()}:fix_issue"}
      )

    {:ok, landed} = Issues.record_fix_landed(ctx.scope, promoting, @head)
    {:ok, _} = Issues.resolve_issue(ctx.scope, landed, "Landed on main.")

    assert Repo.get!(CodeMySpec.Agents.Offer, offered.id).status == :superseded
    assert Repo.get!(CodeMySpec.Agents.Offer, other.id).status == :open
    assert Work.claimable_work(ctx.scope, reload(coding)) == []
    CodeMySpec.Agents.Offers.settle_turn(reload(coding))
    assert Repo.get!(CodeMySpec.Agents.Offer, offered.id).status == :superseded
  end

  test "a direct resolve_issue frees the team instead of re-offering qa_complete", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    qa = agent(ctx.scope, :qa, copy_id)

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, landed} = Issues.record_fix_landed(ctx.scope, ctx.issue, @head)
    {:ok, _} = Issues.resolve_issue(ctx.scope, landed, "Landed on main.")

    assert %{status: :blocked, actionable: []} = IssueWork.execution(ctx.scope, reload(qa))
    assert reload(qa).issue_id == nil
    assert reload(coding).issue_id == nil
  end

  test "a direct dismiss_issue frees the team the same way", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    qa = agent(ctx.scope, :qa, copy_id)

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.dismiss_issue(ctx.scope, ctx.issue, "Not real.")

    assert %{status: :blocked, actionable: []} = IssueWork.execution(ctx.scope, reload(coding))
    assert reload(coding).issue_id == nil
    assert reload(qa).issue_id == nil
  end

  test "freeing settles into waiting-for-main rather than looping", ctx do
    copy_id = copy(ctx.scope)
    qa = agent(ctx.scope, :qa, copy_id)

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, landed} = Issues.record_fix_landed(ctx.scope, ctx.issue, @head)
    {:ok, _} = Issues.resolve_issue(ctx.scope, landed, "Landed on main.")

    assert %{status: :blocked} = IssueWork.execution(ctx.scope, reload(qa))

    assert %{status: :blocked, reason: reason} = IssueWork.execution(ctx.scope, reload(qa))
    assert reason =~ "Waiting for main assignment"
  end

  # The submitted fix hands the turn to QA and the issue records that on
  # itself (775b7cea). `claimable_work/3` is what `get_next_requirement` and
  # `list_agent_work` read; `work_for/4` is what the turn offer reads. An issue
  # is not in the graph, so the menu must name the issue's own node — not
  # project work the offer will never name, which is the notice saying work is
  # available while the menu says it belongs to other roles.
  test "the menu and the offer name the same work for an issue-bound agent", ctx do
    copy_id = copy(ctx.scope)
    qa = agent(ctx.scope, :qa, copy_id)

    {:ok, assigned} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, assigned, :qa)

    qa = reload(qa)
    offer = Work.work_for(ctx.scope, :qa, qa)
    menu = Work.claimable_work(ctx.scope, qa)

    assert Enum.map(menu, & &1.name) == Enum.map(offer.actionable, & &1.name),
           """
           the menu names #{inspect(Enum.map(menu, & &1.name))} and the offer names \
           #{inspect(Enum.map(offer.actionable, & &1.name))}
           """

    # The same *node*, not merely a same-named one: a graph node called
    # qa_complete would belong to a story, and this must be the issue's own.
    assert [%{entity_type: "issue", entity_id: entity_id}] = menu
    assert entity_id == ctx.issue.id
  end

  # 44a4a121, seen twice on 2026-10-19: a coder declined its assigned issue's
  # offer while it waited on main's answer, and its own start_task then
  # answered "Requirement fix_issue not found" with nothing main could do. A
  # decline must leave the work visible and claimable when the agent pulls.
  # Product clarified this behavior on issue 006b2b56.
  test "a file change lifts an earlier decline through the graph wake", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    key = "issue:#{ctx.issue.id}:fix_issue"
    declined = Offers.record_declined(coding, :work, {"requirement", key}, "waiting for changes")
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    CodeMySpec.Agents.GraphWake.handle_event(
      CodeMySpec.Agents.GraphWake.event(),
      %{},
      %{
        scope: ctx.scope,
        changes: [
          %{
            kind: "files_synced",
            working_copy_id: copy_id,
            inserted_at: NaiveDateTime.add(DateTime.to_naive(declined.outcome_at), 1, :second)
          }
        ]
      },
      nil
    )

    :ok = CodeMySpecSpex.Fixtures.drain_background_work()
    assert Repo.get!(CodeMySpec.Agents.Offer, declined.id).status == :superseded
  end

  test "a stale change or another checkout does not lift a decline", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    key = "issue:#{ctx.issue.id}:fix_issue"
    declined = Offers.record_declined(coding, :work, {"requirement", key}, "waiting")

    Offers.lift_copy_declines(ctx.scope, copy_id, DateTime.add(declined.outcome_at, -1, :second))
    assert Repo.get!(CodeMySpec.Agents.Offer, declined.id).status == :declined
    Offers.lift_copy_declines(ctx.scope, copy(ctx.scope), DateTime.utc_now())
    assert Repo.get!(CodeMySpec.Agents.Offer, declined.id).status == :declined
  end

  test "a teammate completing work lifts a prior decline and permits a fresh offer", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    qa = agent(ctx.scope, :qa, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    key = "issue:#{ctx.issue.id}:fix_issue"
    declined = Offers.record_declined(coding, :work, {"requirement", key}, "waiting for teammate")
    assert %{held?: true} = Offers.standing(coding.id)[key]

    CodeMySpec.Agents.Events.handle_event(
      [:code_my_spec, :tasks, :completed],
      %{},
      %{scope: ctx.scope, working_copy_id: copy_id, except_agent_id: qa.id},
      nil
    )

    assert Repo.get!(CodeMySpec.Agents.Offer, declined.id).status == :superseded
    refute match?(%{held?: true}, Offers.standing(coding.id)[key])
    assert {:ok, fresh} = Offers.dispatch(coding, :work, {"requirement", key})
    assert fresh.id != declined.id
    assert fresh.status == :open
  end

  test "an agent that declined its issue's offer can still claim it by name", ctx do
    %{scope: scope, copy_id: copy_id} = certifiable_copy(ctx.scope)
    coding = agent(scope, :coding, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(scope, ctx.issue.id, copy_id)

    Offers.record_declined(
      coding,
      :work,
      {"requirement", "issue:#{ctx.issue.id}:fix_issue"},
      "waiting on main's answer"
    )

    assert [%{name: "fix_issue", entity_id: issue_id}] = Work.claimable_work(scope, coding)
    assert issue_id == ctx.issue.id

    assert {:ok, text} =
             ToolLibrary.run("get_next_requirement", %{}, %{scope: scope, agent_id: coding.id})

    assert text =~ "fix_issue"
    assert text =~ "you declined this at"
    assert text =~ "waiting on main's answer"
    refute text =~ "held by a teammate"

    params = %{requirement_name: "fix_issue", entity_type: "issue", entity_id: ctx.issue.id}

    assert {:ok, _} =
             ToolLibrary.run("start_task", params, %{scope: scope, agent_id: coding.id})

    assert [%{requirement_name: "fix_issue", status: :active}] = reload(coding).tasks
  end
end
