defmodule CodeMySpec.Agents.AssignmentTest do
  @moduledoc """
  a31f1cd6 step 3: the team on a copy — its coding and QA agents — works one
  story together, held on each agent. The copy records no story of its own.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    coding = agent(scope, :coding)
    qa = agent(scope, :qa)
    first = story_fixture(scope)
    second = story_fixture(scope)
    CodeMySpec.Requirements.recompute(scope)
    %{scope: scope, coding: coding, qa: qa, first: first, second: second}
  end

  defp agent(scope, role, copy_id \\ nil) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: role,
        status: :running,
        working_copy_id: copy_id || scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    agent
  end

  defp call(name, scope, params, agent) when is_binary(name) do
    name |> ToolLibrary.run(params, Map.put(assigns(scope, agent), :scope, scope)) |> flagged()
  end

  defp call(tool, scope, params, agent) do
    {:reply, response, _frame} = tool.execute(params, %Frame{assigns: assigns(scope, agent)})
    {response.isError, hd(Response.to_protocol(response)["content"])["text"]}
  end

  defp flagged({:ok, text}), do: {false, text}
  defp flagged({:error, text}), do: {true, text}

  defp assigns(scope, nil), do: %{current_scope: scope}
  defp assigns(scope, agent), do: %{current_scope: scope, agent_id: agent.id}

  defp pick(scope, story, agent \\ nil) do
    {false, text} = call(SetActiveStory, scope, %{story_number: story && story.number}, agent)
    text
  end

  defp next(scope, agent \\ nil) do
    {false, text} = call("get_next_requirement", scope, %{}, agent)
    text
  end

  defp reload(agent), do: Repo.get!(Agents.Agent, agent.id)
  defp placement(story), do: Repo.get!(Story, story.id).working_copy_id

  defp retire(agent) do
    agent
    |> Ecto.Changeset.change(retired_at: DateTime.utc_now())
    |> Repo.update!()
  end

  @tag criterion: 2083
  test "assigning a story clears the issue bag and cancels open issue attempts", ctx do
    first = CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{status: :accepted})
    second = CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{status: :accepted})
    copy_id = ctx.scope.active_working_copy_id
    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, first.id, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, second.id, copy_id)

    {:ok, coding} =
      CodeMySpec.TaskOwner.add_task(ctx.scope, reload(ctx.coding), %{
        status: :blocked,
        issue_id: first.id,
        requirement_name: "fix_issue",
        session_type: CodeMySpec.AgentTasks.IssueFix
      })

    [attempt] = coding.tasks

    pick(ctx.scope, ctx.first)

    assert Agents.IssueAssignment.bag(ctx.scope, copy_id) == []

    for member <- [ctx.coding, ctx.qa] do
      assert reload(member).story_id == ctx.first.id
      assert reload(member).issue_id == nil
    end

    for issue <- [first, second] do
      remaining = CodeMySpec.Issues.get_issue(ctx.scope, issue.id)
      assert remaining.assigned_working_copy_id == nil
      assert remaining.status == :accepted
    end

    assert [%{id: id, status: :cancelled}] = reload(coding).tasks
    assert id == attempt.id
  end

  test "assigning an issue clears the active story and queued reservations", ctx do
    pick(ctx.scope, ctx.first)
    copy_id = ctx.scope.active_working_copy_id
    {:ok, _} = Stories.reserve_story(ctx.scope, copy_id, ctx.second.id)
    issue = CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{status: :accepted})

    {:ok, coding} =
      CodeMySpec.TaskOwner.add_task(ctx.scope, reload(ctx.coding), %{
        status: :blocked,
        story_id: ctx.first.id,
        requirement_name: "ready_for_qa",
        session_type: CodeMySpec.AgentTasks.ReadyForQa
      })

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, issue.id, copy_id)

    assert placement(ctx.first) == nil
    assert placement(ctx.second) == nil

    for member <- [ctx.coding, ctx.qa] do
      assert reload(member).story_id == nil
      assert reload(member).issue_id == issue.id
    end

    assert [%{status: :cancelled}] = reload(coding).tasks
  end

  @tag criterion: 2084
  test "a refused story assignment preserves the issue bag", ctx do
    issue = CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{status: :accepted})
    copy_id = ctx.scope.active_working_copy_id
    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, issue.id, copy_id)
    assert {:error, _} = Agents.Assignment.assign_team(ctx.scope, copy_id, -1)
    assert [%{id: id}] = Agents.IssueAssignment.bag(ctx.scope, copy_id)
    assert id == issue.id
    assert reload(ctx.coding).issue_id == issue.id
  end

  test "the coder and the QA on one copy share its story", ctx do
    pick(ctx.scope, ctx.first, ctx.coding)

    assert reload(ctx.coding).story_id == ctx.first.id
    assert reload(ctx.qa).story_id == ctx.first.id
    assert next(ctx.scope, ctx.coding) =~ "# Story #{ctx.first.number}:"
    assert next(ctx.scope, ctx.qa) =~ "# Story #{ctx.first.number}:"
  end

  test "one agent selecting a story moves the whole team", ctx do
    pick(ctx.scope, ctx.first, ctx.qa)
    pick(ctx.scope, ctx.second, ctx.coding)

    assert reload(ctx.coding).story_id == ctx.second.id
    assert reload(ctx.qa).story_id == ctx.second.id
  end

  test "the main agent's selection goes to the team, not to itself", ctx do
    main = agent(ctx.scope, :main)
    pick(ctx.scope, ctx.first, main)

    assert reload(ctx.coding).story_id == ctx.first.id
    assert reload(ctx.qa).story_id == ctx.first.id
    assert reload(main).story_id == nil
  end

  test "a session selects for the team and reads the team's story", ctx do
    pick(ctx.scope, ctx.first)

    assert reload(ctx.qa).story_id == ctx.first.id
    assert next(ctx.scope) =~ "# Story #{ctx.first.number}:"
  end

  test "a copy with no team has nobody to give a story to", ctx do
    {:ok, other} =
      WorkingCopies.issue(ctx.scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(ctx.scope)
      )

    scope = %{ctx.scope | active_working_copy_id: other.id}

    assert {true, text} =
             call(SetActiveStory, scope, %{story_number: ctx.first.number}, nil)

    assert text =~ "No coding or QA agent"
  end

  test "promotion clears only the finished story and leaves its queue and history", ctx do
    {:ok, main_copy} =
      WorkingCopies.issue(ctx.scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(ctx.scope)
      )

    {:ok, _} = WorkingCopies.designate_main(ctx.scope, main_copy.id)
    main = agent(ctx.scope, :main, main_copy.id)
    :ok = AgentPresence.absent(main)
    pick(ctx.scope, ctx.first)

    {:ok, _} =
      Stories.reserve_story(ctx.scope, ctx.scope.active_working_copy_id, ctx.second.id)

    {:ok, landed} = CodeMySpec.Stories.mark_story_promoted(ctx.scope, ctx.first, "2.0.99")

    assert :ok =
             Agents.Assignment.notify_team_free(
               ctx.scope,
               ctx.scope.active_working_copy_id,
               landed
             )

    for member <- [ctx.coding, ctx.qa] do
      assert reload(member).story_id == nil
      assert reload(member).team_free_at
    end

    assert placement(ctx.first) == nil
    assert placement(ctx.second) == ctx.scope.active_working_copy_id
    assert Repo.get!(Story, ctx.first.id).promoted_version == "2.0.99"
    assert next(ctx.scope, ctx.coding) =~ "Waiting for main assignment"
    assert [%{status: :open}] = Agents.Offers.list_for_agent(main.id)

    assert :ok =
             Agents.Assignment.notify_team_free(
               ctx.scope,
               ctx.scope.active_working_copy_id,
               landed
             )

    assert length(Agents.Offers.list_for_agent(main.id)) == 1

    pick(ctx.scope, ctx.second)
    assert reload(ctx.coding).team_free_at == nil

    assert :ok =
             Agents.Assignment.notify_team_free(
               ctx.scope,
               ctx.scope.active_working_copy_id,
               landed
             )

    assert reload(ctx.coding).story_id == ctx.second.id
    assert reload(ctx.qa).story_id == ctx.second.id
    assert placement(ctx.second) == ctx.scope.active_working_copy_id
  end

  test "a promoted story leaves remaining issue work assigned", ctx do
    pick(ctx.scope, ctx.first)

    issue =
      CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{
        status: :accepted,
        story_id: ctx.first.id
      })

    {:ok, _} =
      Agents.assign_issue_to_working_copy(ctx.scope, issue.id, ctx.scope.active_working_copy_id)

    {:ok, landed} = CodeMySpec.Stories.mark_story_promoted(ctx.scope, ctx.first, "2.0.99")
    :ok = Agents.Assignment.notify_team_free(ctx.scope, ctx.scope.active_working_copy_id, landed)

    for member <- [ctx.coding, ctx.qa] do
      assert reload(member).story_id == nil
      assert reload(member).issue_id == issue.id
      assert reload(member).team_free_at == nil
    end

    assert [%{id: id}] = Agents.assigned_issues(ctx.scope, ctx.scope.active_working_copy_id)
    assert id == issue.id
  end

  test "an unlanded story cannot clear its team", ctx do
    pick(ctx.scope, ctx.first)

    assert :ok =
             Agents.Assignment.notify_team_free(
               ctx.scope,
               ctx.scope.active_working_copy_id,
               ctx.first
             )

    assert reload(ctx.coding).story_id == ctx.first.id
    assert placement(ctx.first) == ctx.scope.active_working_copy_id
  end

  describe "main" do
    setup ctx do
      {:ok, main_copy} =
        WorkingCopies.issue(ctx.scope, nil,
          device: CodeMySpec.DevicesFixtures.device_fixture(ctx.scope)
        )

      {:ok, _} = CodeMySpec.Staffing.designate_main(ctx.scope, main_copy.id)
      main_scope = %{ctx.scope | active_working_copy_id: main_copy.id}
      %{main_copy: main_copy, main_scope: main_scope, main: agent(main_scope, :main)}
    end

    test "steers a feature copy's team by naming it, and holds no story itself", ctx do
      params = %{
        story_number: ctx.first.number,
        working_copy_id: ctx.scope.active_working_copy_id
      }

      {false, _text} = call(SetActiveStory, ctx.main_scope, params, ctx.main)

      assert reload(ctx.coding).story_id == ctx.first.id
      assert reload(ctx.qa).story_id == ctx.first.id
      assert reload(ctx.main).story_id == nil
    end

    test "the main copy is never given a story", ctx do
      assert {:error, :main_copy} =
               Agents.assign_team(ctx.main_scope, ctx.main_copy.id, ctx.first.id)

      params = %{story_number: ctx.first.number}
      assert {true, text} = call(SetActiveStory, ctx.main_scope, params, ctx.main)
      assert text =~ "feature copies"
    end

    test "only main may name another copy", ctx do
      params = %{story_number: ctx.first.number, working_copy_id: ctx.main_copy.id}

      assert {true, text} = call(SetActiveStory, ctx.scope, params, ctx.coding)
      assert text =~ "Only the main agent"
      assert reload(ctx.coding).story_id == nil
    end

    test "never holds a story: not by creation, inheritance or assignment", ctx do
      pick(ctx.scope, ctx.first)

      on_team_copy = agent(ctx.scope, :main)
      assert on_team_copy.story_id == nil
      assert reload(on_team_copy).story_id == nil

      assert {:error, changeset} =
               AgentsRepository.create_agent(ctx.scope, %{
                 engine: :alloy,
                 provider: "zai",
                 working_copy: "/tmp/a-copy",
                 role: :main,
                 working_copy_id: ctx.scope.active_working_copy_id,
                 story_id: ctx.first.id
               })

      assert %{story_id: [_]} = errors_on(changeset)
    end

    test "reads no story even on a copy whose team holds one", ctx do
      pick(ctx.scope, ctx.first)
      on_team_copy = agent(ctx.scope, :main)

      assert Agents.Work.work_for(ctx.scope, :main, on_team_copy).story == nil
      assert Agents.Work.work_for(ctx.scope, :coding, reload(ctx.coding)).story.id == ctx.first.id
    end
  end

  test "product holds the epic, never a story", ctx do
    pick(ctx.scope, ctx.first)
    product = agent(ctx.scope, :product)

    assert product.story_id == nil

    assert {:error, changeset} =
             product |> Agents.Agent.changeset(%{story_id: ctx.first.id}) |> Repo.update()

    assert %{story_id: [_]} = errors_on(changeset)
  end

  test "switching releases the story the team moved off", ctx do
    pick(ctx.scope, ctx.first)
    pick(ctx.scope, ctx.second)

    assert placement(ctx.first) == nil
    assert placement(ctx.second) == ctx.scope.active_working_copy_id

    pick(ctx.scope, nil)

    assert placement(ctx.second) == nil
    assert reload(ctx.coding).story_id == nil
  end

  # 3f824f74: a reservation (`stories.working_copy_id`) and a team's own
  # `story_id` drift apart the moment an agent holding it is retired and
  # replaced -- the replacement's `story_id` is nil, so the reservation can
  # never again appear in the set a clear computes from the team.
  test "a reservation orphaned by a retired, replaced agent is still released", ctx do
    pick(ctx.scope, ctx.first)
    assert placement(ctx.first) == ctx.scope.active_working_copy_id

    retire(ctx.coding)
    retire(ctx.qa)
    _replacement_coding = agent(ctx.scope, :coding)
    _replacement_qa = agent(ctx.scope, :qa)

    pick(ctx.scope, nil)

    assert placement(ctx.first) == nil
  end

  test "a teamless copy still releases what it reserves when cleared", ctx do
    pick(ctx.scope, ctx.first)
    assert placement(ctx.first) == ctx.scope.active_working_copy_id

    retire(ctx.coding)
    retire(ctx.qa)

    assert {false, text} = call(SetActiveStory, ctx.scope, %{}, nil)
    assert text =~ "is free"
    assert placement(ctx.first) == nil
  end

  test "an agent joining the copy inherits the team's story", ctx do
    pick(ctx.scope, ctx.first)

    joiner = agent(ctx.scope, :qa)

    assert joiner.story_id == ctx.first.id
  end

  describe "claiming a story's work" do
    test "outside the team's story is refused, and nobody moves", ctx do
      pick(ctx.scope, ctx.first)

      first_id = ctx.first.id

      assert {:error, {:outside_team_story, ^first_id}} =
               Agents.claim_story(ctx.scope, reload(ctx.coding), ctx.second.id)

      assert reload(ctx.coding).story_id == ctx.first.id
      assert reload(ctx.qa).story_id == ctx.first.id
    end

    test "inside the team's story is allowed", ctx do
      pick(ctx.scope, ctx.first)

      assert :ok = Agents.claim_story(ctx.scope, reload(ctx.qa), ctx.first.id)
    end

    test "with no team story assigns the story to the whole team", ctx do
      assert :ok = Agents.claim_story(ctx.scope, ctx.coding, ctx.second.id)

      assert reload(ctx.coding).story_id == ctx.second.id
      assert reload(ctx.qa).story_id == ctx.second.id
      assert placement(ctx.second) == ctx.scope.active_working_copy_id
    end
  end

  describe "an epic placed on a copy" do
    setup ctx do
      {:ok, epic} = Epics.create_epic(ctx.scope, %{name: "Placed work"})

      for story <- [ctx.first, ctx.second],
          do: story |> Ecto.Changeset.change(epic_id: epic.id) |> Repo.update!()

      %{epic: epic}
    end

    # Step 4c: product designs the epic on the main copy and is not sent with
    # it; coding and QA build it.
    test "gives the epic to the team, not product or main", ctx do
      main = agent(ctx.scope, :main)
      product = agent(ctx.scope, :product)

      {:ok, 2} = EpicDispatch.place(ctx.scope, ctx.epic.id, ctx.scope.active_working_copy_id)
      :ok = Agents.assign_epic(ctx.scope, ctx.epic.id, ctx.scope.active_working_copy_id)

      assert reload(ctx.coding).epic_id == ctx.epic.id
      assert reload(ctx.qa).epic_id == ctx.epic.id
      assert reload(product).epic_id == nil
      assert reload(main).epic_id == nil
    end

    test "an agent joining later inherits the epic", ctx do
      {:ok, _} = EpicDispatch.place(ctx.scope, ctx.epic.id, ctx.scope.active_working_copy_id)
      :ok = Agents.assign_epic(ctx.scope, ctx.epic.id, ctx.scope.active_working_copy_id)

      assert agent(ctx.scope, :coding).epic_id == ctx.epic.id
    end

    test "takes it from the team on the copy it left", ctx do
      {:ok, _} = EpicDispatch.place(ctx.scope, ctx.epic.id, ctx.scope.active_working_copy_id)
      pick(ctx.scope, ctx.first)

      {:ok, other} =
        WorkingCopies.issue(ctx.scope, nil,
          device: CodeMySpec.DevicesFixtures.device_fixture(ctx.scope)
        )

      {:ok, _} = EpicDispatch.place(ctx.scope, ctx.epic.id, other.id)

      assert reload(ctx.coding).story_id == ctx.first.id
      assert placement(ctx.first) == ctx.scope.active_working_copy_id
      assert placement(ctx.second) == other.id

      :ok = Agents.assign_epic(ctx.scope, ctx.epic.id, other.id)

      coding = reload(ctx.coding)
      assert coding.epic_id == nil
      assert coding.story_id == nil
    end
  end
end
