defmodule CodeMySpec.Agents.AStoryBoundAgentIsOfferedOnlyItsStoryTest do
  @moduledoc """
  4292518a. An agent with an active story is bound by it: it is offered, counted
  and may claim only that story's work. A coding agent on story 1083 whose own
  part was done was offered the project-level `issues_resolved` — every open
  issue in the project — and sat on it while 1083 never started. Project-level
  work goes to agents without a story.
  """

  use CodeMySpecSpex.Case, async: true

  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Coding's part of the story is done and QA's is open, so the story holds no
  # coding work; an accepted issue nobody attributed to a story opens the
  # project-level `issues_resolved`, which is coding's.
  setup ctx do
    coding = CodeMySpecSpex.Fixtures.running_agent(ctx.scope, role: "coding")
    qa = CodeMySpecSpex.Fixtures.running_agent(ctx.scope, role: "qa")

    ctx =
      ctx
      |> Map.merge(%{coding: coding, qa: qa})
      |> CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story()
      |> Slice.activate()

    accept(ctx, %{})
    %{ctx | coding: reload(coding)}
  end

  test "QA without its own story discovers and claims its team's QA work", ctx do
    ctx = Slice.waiting(ctx)

    reload(ctx.qa)
    |> Ecto.Changeset.change(story_id: nil)
    |> Repo.update!()

    qa = reload(ctx.qa)
    assert Work.bound_story_id(qa) == ctx.story.id
    answer = Slice.next(ctx, %{agent_id: qa.id})
    assert answer =~ "# Story #{ctx.story.number}:"
    assert answer =~ "qa_complete"
    refute Slice.offered?(answer, ctx.waiting.id)
    assert reload(qa).story_id == nil, "discovery must remain read-only"

    Slice.call(
      ctx,
      "start_task",
      %{
        requirement_name: "qa_complete",
        entity_type: "story",
        entity_id: to_string(ctx.story.number)
      },
      %{agent_id: qa.id}
    )

    assert reload(qa).story_id == ctx.story.id
    assert reload(ctx.coding).story_id == ctx.story.id
  end

  test "the coding agent is bound to the team's story", ctx do
    assert ctx.coding.story_id == ctx.story.id
    assert Work.bound_story_id(ctx.coding) == ctx.story.id
  end

  test "an agent without an active story still gets the project-level issues_resolved", ctx do
    Repo.update_all(Agent, set: [story_id: nil])
    coding = reload(ctx.coding)

    assert Work.bound_story_id(coding) == nil
    assert "issues_resolved" in names(ctx, coding)
  end

  describe "a bound agent whose story holds no work for its role" do
    test "is not offered the project-level issues_resolved", ctx do
      claimable = Work.claimable_work(ctx.scope, ctx.coding)

      refute Enum.any?(claimable, &(&1.name == "issues_resolved"))
      assert claimable == []
    end

    test "get_next_requirement answers about its story, not the project", ctx do
      text = Slice.next(ctx, %{agent_id: ctx.coding.id})

      assert text =~ "# Story #{ctx.story.number}:"
      refute text =~ "issues_resolved"
    end

    test "the turn-end menu counts what it is offered", ctx do
      menu = ctx.scope |> Menu.live(:coding, ctx.coding) |> Keyword.get(:requirements, 0)

      assert menu == length(Work.claimable_work(ctx.scope, ctx.coding))
      assert menu == 0
    end

    test "start_task on the project-level node is refused, naming the story", ctx do
      {error?, text} = start_project(ctx, ctx.coding, "issues_resolved")

      assert error?, text
      assert text =~ "issues_resolved"
      assert text =~ "active story #{ctx.story.number}"
      assert reload(ctx.coding).tasks == []
    end

    test "the same claim is allowed to an agent without a story", ctx do
      Repo.update_all(Agent, set: [story_id: nil])
      {error?, text} = start_project(ctx, reload(ctx.coding), "issues_resolved")

      refute error?, text
    end
  end

  describe "an issue filed against the active story" do
    setup ctx do
      %{story_issue: accept(ctx, %{story_id: ctx.story.id})}
    end

    test "is offered, and the project-level issues_resolved is not", ctx do
      names = names(ctx, ctx.coding)

      assert "submitted" in names
      refute "issues_resolved" in names
    end

    test "get_next_requirement lists only the story's work", ctx do
      claimable = Work.claimable_work(ctx.scope, ctx.coding)
      text = Slice.next(ctx, %{agent_id: ctx.coding.id})

      assert text =~ "submitted"
      refute text =~ ~r/\bissues_resolved \(/
      assert Enum.all?(claimable, &story_work?(ctx, &1))
      assert text =~ "Remaining: #{length(claimable) - 1}"
    end

    test "the menu count matches the offer", ctx do
      menu = ctx.scope |> Menu.live(:coding, ctx.coding) |> Keyword.get(:requirements, 0)

      assert menu == length(Work.claimable_work(ctx.scope, ctx.coding))
      assert menu > 0
    end

    test "the story's issue work can be started", ctx do
      {error?, text} =
        Slice.attempt(
          ctx,
          "start_task",
          %{
            requirement_name: "submitted",
            entity_type: "issue",
            entity_id: ctx.story_issue.id
          },
          %{agent_id: ctx.coding.id}
        )

      refute error?, text
    end
  end

  # Strict and unclamped (John): project-level work, prerequisites included,
  # goes to agents without a story, and does not hold a bound agent's story.
  describe "a project-level requirement the story waits on" do
    setup ctx do
      :ok =
        CodeMySpec.ExecutionContexts.delete_file(
          ctx.execution_context,
          ".code_my_spec/qa/plan.md"
        )

      CodeMySpecSpex.GraphGivens.sync(ctx)
      %{qa: reload(ctx.qa)}
    end

    test "is not offered to the bound agent whose role holds it", ctx do
      assert ctx.qa.story_id == ctx.story.id
      refute "qa_setup" in names(ctx, ctx.qa)
      refute Slice.next(ctx, %{agent_id: ctx.qa.id}) =~ "qa_setup"
    end

    test "and cannot be started by it", ctx do
      {error?, text} = start_project(ctx, ctx.qa, "qa_setup")

      assert error?, text
      assert text =~ "active story #{ctx.story.number}"
    end

    test "does not hold the bound agent's story work back", ctx do
      assert "qa_complete" in names(ctx, ctx.qa)

      menu = ctx.scope |> Menu.live(:qa, ctx.qa) |> Keyword.get(:requirements, 0)
      assert menu == length(Work.claimable_work(ctx.scope, ctx.qa))
      assert Slice.next(ctx, %{agent_id: ctx.qa.id}) =~ "qa_complete"
    end

    test "still holds the story back for an agent without one", ctx do
      Repo.update_all(Agent, set: [story_id: nil])
      names = names(ctx, reload(ctx.qa))

      assert "qa_setup" in names
      refute "qa_complete" in names
    end

    test "a story-internal unsatisfied node still blocks its descendants", ctx do
      accept(ctx, %{story_id: ctx.story.id})

      refute "qa_complete" in names(ctx, ctx.qa),
             "an issue submission is unsatisfied and qa_complete waits on it"

      assert "submitted" in names(ctx, ctx.coding)
    end
  end

  describe "an agent already holding an out-of-story task" do
    test "keeps it, and is offered nothing more outside the story", ctx do
      Repo.update_all(Agent, set: [story_id: nil])
      {false, _text} = start_project(ctx, reload(ctx.coding), "issues_resolved")
      Repo.update_all(Agent, set: [story_id: ctx.story.id])

      coding = reload(ctx.coding)
      assert [%{requirement_name: "issues_resolved", status: :active}] = coding.tasks
      refute "issues_resolved" in names(ctx, coding)
    end
  end

  test "resolving a partial review's unlinked blocker reoffers the same certification", ctx do
    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
    # An app issue: one QA cites from the environment does not hold.
    blocker = accept(ctx, %{scope: :app})

    %CodeMySpec.Qa.QaAttempt{}
    |> CodeMySpec.Qa.QaAttempt.changeset(%{
      story_id: story.id,
      status: :partial,
      scenarios: [%{name: "Browser access", status: :partial, observation: "Tool unavailable"}],
      issue_ids: [blocker.id],
      reviewed_commit: story.qa_ready_commit,
      review_certified_at: story.qa_ready_at,
      review_started_at: DateTime.utc_now(),
      submitted_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    CodeMySpec.Requirements.GraphInputs.event(
      ctx.scope,
      "Qa",
      "qa_attempt_submitted",
      %{},
      [{"story", story.id}],
      :project_wide
    )

    :ok = GraphWatcher.settle(ctx.scope)
    refute "qa_complete" in names(ctx, ctx.qa)

    {:ok, _} = Issues.resolve_issue(ctx.scope, blocker, "Browser access repaired")
    :ok = GraphWatcher.settle(ctx.scope)

    assert "qa_complete" in names(ctx, ctx.qa)
    current = CodeMySpec.Stories.get_story!(ctx.scope, story.id)
    assert current.qa_ready_commit == story.qa_ready_commit
    assert current.qa_ready_at == story.qa_ready_at
  end

  test "resolving a cited blocker cannot release QA after the certified HEAD moved", ctx do
    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
    # An app issue: one QA cites from the environment does not hold.
    blocker = accept(ctx, %{scope: :app})

    %CodeMySpec.Qa.QaAttempt{}
    |> CodeMySpec.Qa.QaAttempt.changeset(%{
      story_id: story.id,
      status: :fail,
      scenarios: [%{name: "Browser access", status: :fail, observation: "Tool unavailable"}],
      issue_ids: [blocker.id],
      reviewed_commit: story.qa_ready_commit,
      review_certified_at: story.qa_ready_at,
      review_started_at: DateTime.utc_now(),
      submitted_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    CodeMySpec.Requirements.GraphInputs.event(
      ctx.scope,
      "Qa",
      "qa_attempt_submitted",
      %{},
      [{"story", story.id}],
      :project_wide
    )

    :ok = GraphWatcher.settle(ctx.scope)
    refute "qa_complete" in names(ctx, ctx.qa)

    new_head = String.duplicate("b", 40)

    [released] =
      CodeMySpec.PromotionQueue.release_moved_certifications(
        ctx.scope,
        ctx.scope.active_working_copy_id,
        new_head
      )

    assert released.id == story.id
    assert is_nil(released.qa_ready_commit)
    {:ok, _} = Issues.resolve_issue(ctx.scope, blocker, "Browser access repaired")
    :ok = GraphWatcher.settle(ctx.scope)

    refute "qa_complete" in names(ctx, ctx.qa)
    assert "ready_for_qa" in names(ctx, ctx.coding)

    {:ok, _} = CodeMySpec.Stories.set_qa_ready(ctx.scope, released, new_head)
    :ok = GraphWatcher.settle(ctx.scope)
    assert "qa_complete" in names(ctx, ctx.qa)
  end

  defp story_work?(ctx, node) do
    (node.entity_type == "story" and to_string(node.entity_id) == to_string(ctx.story.id)) or
      node.entity_type == "component" or
      (node.entity_type == "issue" and node.details["story_id"] == ctx.story.id)
  end

  # Settled, so the graph read next includes the accepted issue: under load an
  # unsettled read still offered qa_complete past the new submission node.
  defp accept(ctx, attrs) do
    issue = issue_fixture(ctx.scope, attrs)
    {:ok, issue} = Issues.accept_issue(ctx.scope, issue)
    :ok = GraphWatcher.settle(ctx.scope)
    issue
  end

  defp names(ctx, agent), do: ctx.scope |> Work.claimable_work(agent) |> Enum.map(& &1.name)

  defp start_project(ctx, agent, name) do
    Slice.attempt(
      ctx,
      "start_task",
      %{
        requirement_name: name,
        entity_type: "project",
        entity_id: to_string(ctx.scope.active_project_id)
      },
      %{agent_id: agent.id}
    )
  end

  defp reload(agent), do: Repo.get!(Agent, agent.id)
end
