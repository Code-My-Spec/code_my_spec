defmodule CodeMySpecWeb.AgentPerformanceLive.IndexTest do
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.AgentPerformanceHelpers

  alias CodeMySpec.Agents
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a stage with no matching tasks shows as unknown, not as zero", context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Promoted with an unmapped task",
        description: "A finished story whose only task does not belong to any named stage."
      })

    {:ok, story} = story |> Story.changeset(%{ready_for_dev: true}) |> Repo.update()

    agent = Fixtures.running_agent(context.scope, role: "coding")
    :ok = Agents.claim_story(context.scope, agent, story.id)

    Fixtures.agent_task_fixture(context.scope, agent,
      story_id: story.id,
      session_type: CodeMySpec.AgentTasks.ResearchTopic,
      started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    )

    {:ok, story} =
      story
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: DateTime.utc_now()})
      |> Repo.update()

    {:ok, index, _html} = live(context.conn, index_path(context))
    html = render_async(index)

    assert html =~ story.title

    cycle_time = index |> element("[data-test='cycle-time']") |> render()

    refute cycle_time =~ "Total: unknown",
           "the story's own total release-to-promotion time could not be computed"

    specs_stage = index |> element("[data-test='stage'][data-stage='specs']") |> render()

    assert specs_stage =~ "unknown",
           "a stage with no matching tasks is not shown as unknown"

    refute specs_stage =~ "0h",
           "a stage with no matching tasks is shown as though no time at all was spent on it"
  end

  test "the cycle-time card notes that stages can overlap and may exceed the total", context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Promoted with a single task",
        description: "Enough for a cycle-time card to render."
      })

    {:ok, story} = story |> Story.changeset(%{ready_for_dev: true}) |> Repo.update()

    agent = Fixtures.running_agent(context.scope, role: "coding")
    :ok = Agents.claim_story(context.scope, agent, story.id)

    Fixtures.agent_task_fixture(context.scope, agent,
      story_id: story.id,
      session_type: CodeMySpec.AgentTasks.ComponentCode,
      started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    )

    {:ok, _story} =
      story
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: DateTime.utc_now()})
      |> Repo.update()

    {:ok, index, _html} = live(context.conn, index_path(context))
    _html = render_async(index)

    cycle_time = index |> element("[data-test='cycle-time']") |> render()

    assert cycle_time =~ "Stages can overlap",
           "the cycle-time card does not say that stages can overlap and may exceed the total"
  end
end
