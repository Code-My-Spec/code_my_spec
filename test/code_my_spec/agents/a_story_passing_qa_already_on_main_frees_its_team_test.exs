defmodule CodeMySpec.Agents.AStoryPassingQaAlreadyOnMainFreesItsTeamTest do
  @moduledoc """
  A story whose QA passes with its work already on main frees its team, and
  main is told, as a landing would tell it.

  Story 1016 passed QA at 04:45 with nothing left to land: its promotion stamp
  was current and team 2's commit was on main. No promotion was coming, so no
  landing announced the team free, and team 2 sat idle for seven hours with
  main never told (2026-10-13).
  """
  use CodeMySpecTest.DataCase, async: true

  import Ecto.Query
  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo
  alias CodeMySpec.Staffing
  alias CodeMySpec.Stories
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)
    {:ok, _} = Staffing.designate_main(scope, scope.active_working_copy_id)
    main = agent(scope, :main, scope.active_working_copy_id)

    {:ok, team} =
      CodeMySpec.WorkingCopies.issue(scope, nil, label: "team 2", device: device_fixture(scope))

    story = story_fixture(scope, %{ready_for_dev: true})
    {:ok, story} = Stories.update_story(scope, story, %{working_copy_id: team.id})

    story =
      story
      |> Ecto.Changeset.change(qa_ready_at: DateTime.utc_now(), qa_ready_commit: "on-main")
      |> Repo.update!()

    coder = agent(scope, :coding, team.id, story.id)
    qa = agent(scope, :qa, team.id, story.id)

    %{scope: scope, main: main, team: team, story: story, coder: coder, qa: qa}
  end

  defp agent(scope, role, copy_id, story_id \\ nil) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :running,
        continuous: true,
        working_copy: "/tmp/qa-frees-#{System.unique_integer([:positive])}",
        working_copy_id: copy_id,
        story_id: story_id
      })

    AgentPresence.present(agent)
    agent
  end

  # The work landed earlier: stamped with the time a promotion records.
  defp landed(ctx) do
    {:ok, story} =
      Stories.mark_story_promoted(ctx.scope, ctx.story, "2.0.11",
        at: DateTime.add(DateTime.utc_now(), -3600, :second)
      )

    %{ctx | story: story}
  end

  defp pass_qa(ctx) do
    task_id = Ecto.UUID.generate()

    {:ok, qa} =
      ctx.qa
      |> Agent.add_task(%{
        id: task_id,
        status: :active,
        requirement_name: "qa_complete",
        story_id: ctx.story.id,
        started_at: DateTime.utc_now()
      })
      |> Repo.update()

    task = Enum.find(qa.tasks, &(&1.id == task_id))
    {:ok, _review} = Qa.capture_story_review(ctx.scope, qa, task)

    {:ok, _attempt} =
      Qa.submit_qa_result(ctx.scope, %{
        task_id: task_id,
        status: :pass,
        scenarios: [%{"name" => "suite", "status" => "pass", "observation" => "12/12 spex"}]
      })
  end

  defp team_free_offers(ctx) do
    from(o in Offer,
      where: o.agent_id == ^ctx.main.id and o.kind == :team_free and o.subject_key == ^ctx.team.id
    )
    |> Repo.all()
  end

  test "a pass on a story already on main tells main its team is free", ctx do
    ctx = landed(ctx)
    pass_qa(ctx)

    assert [_offer] = team_free_offers(ctx),
           "QA passed a story with nothing left to land and main was not told the team is free"
  end

  test "a pass on a story still to be promoted keeps its team for the landing", ctx do
    pass_qa(ctx)

    assert team_free_offers(ctx) == []
  end
end
