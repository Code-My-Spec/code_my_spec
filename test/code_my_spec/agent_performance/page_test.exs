defmodule CodeMySpec.AgentPerformance.PageTest do
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.AgentPerformance.Page
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.TaskOwner
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a story's own report ignores a sibling story's tasks even when they share a component",
       context do
    shared_component_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, story_a} =
      Stories.create_story(context.scope, %{
        title: "Story A on a shared component",
        description: "Its own report must not include story B's work."
      })

    {:ok, story_a} =
      story_a |> Story.changeset(%{component_id: shared_component_id}) |> CodeMySpec.Repo.update()

    {:ok, story_b} =
      Stories.create_story(context.scope, %{
        title: "Story B on the same shared component",
        description: "Its own QA task must not leak into story A's report."
      })

    {:ok, story_b} =
      story_b |> Story.changeset(%{component_id: shared_component_id}) |> CodeMySpec.Repo.update()

    # Story A's own build task: component-scoped, no story_id of its own --
    # the legitimate component_id fallback, shared by every story on it.
    agent_a = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, _agent_a} =
      TaskOwner.add_task(context.scope, agent_a, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "implementation_file",
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        component_id: shared_component_id,
        started_at: DateTime.add(now, -1800, :second)
      })

    # Story B's own QA task: tagged with story B's own story_id, far older
    # than story A's whole life. Sharing the same component must not pull
    # it into story A's report (issue 9c2107a6).
    agent_b = Fixtures.running_agent(context.scope, role: "qa")

    {:ok, _agent_b} =
      TaskOwner.add_task(context.scope, agent_b, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "qa_complete",
        session_type: CodeMySpec.AgentTasks.QaStory,
        component_id: shared_component_id,
        story_id: story_b.id,
        started_at: DateTime.add(now, -100 * 3600, :second)
      })

    {:ok, story_a} =
      story_a
      |> Story.changeset(%{
        promoted_version: "0.1.0",
        promoted_at: DateTime.add(now, -900, :second)
      })
      |> CodeMySpec.Repo.update()

    page = Page.load(context.scope)
    report_a = Map.fetch!(page.reports, story_a.id)

    assert report_a.cycle_time.total_seconds == 900,
           "story B's much older task leaked into story A's release-to-promotion window"

    assert Map.get(report_a.cycle_time.stages, :qa, 0) == 0,
           "story B's own QA task was attributed to story A's report because they share a component"

    # Story A's own component-scoped build task still counts -- the
    # legitimate fallback must survive the fix.
    # Never given a completed_at, so per the promotion-bounding fix (a11bf1188)
    # its active span is clipped to the story's own promotion (900s before
    # now), not its full nominal 1800s span: 1800 - 900 = 900.
    assert Map.get(report_a.cycle_time.stages, :build) == 900,
           "story A's own component-scoped build task is missing from its report"
  end
end
