defmodule CodeMySpec.AgentPerformance.CycleTimeTest do
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.AgentPerformance.CycleTime
  alias CodeMySpec.AgentPerformance.Stage
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.TaskOwner
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a stage's time is bounded by the story's own promotion, not by real time", context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Promoted with an abandoned QA task",
        description: "A QA task left open past the story's own promotion."
      })

    now = DateTime.utc_now()
    released_at = DateTime.add(now, -10 * 3600, :second)
    promoted_at = DateTime.add(now, -5 * 3600, :second)

    {:ok, story} =
      story
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: promoted_at})
      |> CodeMySpec.Repo.update()

    abandoned_qa_task = %{
      session_type: CodeMySpec.AgentTasks.QaStory,
      started_at: released_at,
      completed_at: nil,
      story_id: story.id,
      component_id: nil,
      blocked_at: nil,
      blocker_resolved_at: nil,
      blocker_type: nil
    }

    cycle_time = CycleTime.story(context.scope, story, [abandoned_qa_task])

    assert cycle_time.total_seconds == 5 * 3600

    assert cycle_time.stages[:qa] == 5 * 3600,
           "an open task's active time is not bounded to the story's own promotion"

    assert cycle_time.stages[:qa] <= cycle_time.total_seconds,
           "a stage's time exceeds the story's own total release-to-promotion time"
  end

  test "a stage's time is not double-counted across several overlapping, never-completed tasks",
       context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Promoted after several reopened QA rounds",
        description: "Three never-completed QA tasks whose spans overlap in wall-clock time."
      })

    now = DateTime.utc_now()
    released_at = DateTime.add(now, -10 * 3600, :second)
    promoted_at = DateTime.add(now, -5 * 3600, :second)

    {:ok, story} =
      story
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: promoted_at})
      |> CodeMySpec.Repo.update()

    # Three QA rounds reopened across harness restarts, none ever stamped
    # completed_at: each individually bounded to the story's own promotion,
    # but all three overlap the same five hours, so summing their spans
    # naively would read 5h + 4h + 3h = 12h against a 5h story.
    overlapping_qa_tasks =
      for offset <- [0, 1, 2] do
        %{
          session_type: CodeMySpec.AgentTasks.QaStory,
          started_at: DateTime.add(released_at, offset * 3600, :second),
          completed_at: nil,
          story_id: story.id,
          component_id: nil,
          blocked_at: nil,
          blocker_resolved_at: nil,
          blocker_type: nil
        }
      end

    cycle_time = CycleTime.story(context.scope, story, overlapping_qa_tasks)

    assert cycle_time.total_seconds == 5 * 3600

    assert cycle_time.stages[:qa] == 5 * 3600,
           "overlapping tasks' wall-clock time is double-counted instead of unioned"

    assert cycle_time.stages[:qa] <= cycle_time.total_seconds,
           "a stage's time exceeds the story's own total release-to-promotion time"
  end

  test "a story's cycle time ignores another story's own tasks even when they share a component",
       context do
    shared_component_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, story_a} =
      Stories.create_story(context.scope, %{
        title: "Story A on a shared component",
        description: "Should see only its own tasks in its cycle time."
      })

    {:ok, story_a} =
      story_a |> Story.changeset(%{component_id: shared_component_id}) |> CodeMySpec.Repo.update()

    {:ok, story_b} =
      Stories.create_story(context.scope, %{
        title: "Story B on the same shared component",
        description: "Its own QA task must not leak into story A's cycle time."
      })

    {:ok, story_b} =
      story_b |> Story.changeset(%{component_id: shared_component_id}) |> CodeMySpec.Repo.update()

    # Story A's own build task, tagged with its own story_id -- the clock
    # its own released_at anchors on.
    agent_a = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, _agent_a} =
      TaskOwner.add_task(context.scope, agent_a, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "implementation_file",
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        component_id: shared_component_id,
        story_id: story_a.id,
        started_at: DateTime.add(now, -1800, :second)
      })

    # Story B's own QA task: tagged with story B's own story_id, far older
    # than story A's whole life. Sharing the same component must not pull
    # it into story A's task list.
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

    cycle_time = CycleTime.story(context.scope, story_a)

    assert cycle_time.total_seconds == 900,
           "story B's much older task leaked into story A's release-to-promotion window"

    assert Map.get(cycle_time.stages, :qa, 0) == 0,
           "story B's own QA task was attributed to story A because they share a component"
  end

  test "a shared component's own task does not pin every sibling's release moment to the same clock",
       context do
    shared_component_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    # The component's own earliest task, shared by every story that reuses
    # it, with no story_id of its own -- the legitimate component_id
    # fallback. It predates both siblings by a wide margin (issue 04830e20).
    ancient_agent = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, _ancient_agent} =
      TaskOwner.add_task(context.scope, ancient_agent, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "implementation_file",
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        component_id: shared_component_id,
        started_at: DateTime.add(now, -1000 * 3600, :second)
      })

    {:ok, story_a} =
      Stories.create_story(context.scope, %{
        title: "Story A reusing an old shared component",
        description: "Its own Total must come from its own work."
      })

    {:ok, story_a} =
      story_a |> Story.changeset(%{component_id: shared_component_id}) |> CodeMySpec.Repo.update()

    {:ok, story_b} =
      Stories.create_story(context.scope, %{
        title: "Story B reusing the same old shared component",
        description: "Its own Total must differ from story A's."
      })

    {:ok, story_b} =
      story_b |> Story.changeset(%{component_id: shared_component_id}) |> CodeMySpec.Repo.update()

    agent_a = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, _agent_a} =
      TaskOwner.add_task(context.scope, agent_a, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "implementation_file",
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        component_id: shared_component_id,
        story_id: story_a.id,
        started_at: DateTime.add(now, -3600, :second)
      })

    agent_b = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, _agent_b} =
      TaskOwner.add_task(context.scope, agent_b, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "implementation_file",
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        component_id: shared_component_id,
        story_id: story_b.id,
        started_at: DateTime.add(now, -7200, :second)
      })

    {:ok, story_a} =
      story_a
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: now})
      |> CodeMySpec.Repo.update()

    {:ok, story_b} =
      story_b
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: now})
      |> CodeMySpec.Repo.update()

    cycle_time_a = CycleTime.story(context.scope, story_a)
    cycle_time_b = CycleTime.story(context.scope, story_b)

    assert cycle_time_a.total_seconds == 3600,
           "story A's Total is not anchored on its own task's started_at"

    assert cycle_time_b.total_seconds == 7200,
           "story B's Total is not anchored on its own task's started_at"

    refute cycle_time_a.total_seconds == cycle_time_b.total_seconds,
           "both siblings' Total are pinned to the same shared component task"

    # The shared component's own task time counts toward each story's
    # build stage, but clamped to that story's own [released_at, as_of]
    # window -- the ancient task predates both windows entirely, so each
    # story's build stage reads exactly its own total, not the ancient
    # task's full, unclamped span (issue 9c2107a6).
    assert cycle_time_a.stages[:build] == 3600
    assert cycle_time_b.stages[:build] == 7200

    assert cycle_time_a.stages[:build] <= cycle_time_a.total_seconds
    assert cycle_time_b.stages[:build] <= cycle_time_b.total_seconds
  end

  test "a task's own completed_at past the story's promotion does not inflate its stage",
       context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Promoted while its own QA task's completed_at lagged behind",
        description: "A QA task recorded as completed after the story's own promotion."
      })

    now = DateTime.utc_now()
    released_at = DateTime.add(now, -10 * 3600, :second)
    promoted_at = DateTime.add(now, -5 * 3600, :second)

    {:ok, story} =
      story
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: promoted_at})
      |> CodeMySpec.Repo.update()

    # completed_at is stamped two hours AFTER the story's own promotion --
    # not nil, so the old fallback (`task.completed_at || as_of`) would
    # trust it as-is, letting the qa stage run past the story's own total
    # (issue 9c2107a6).
    late_completed_qa_task = %{
      session_type: CodeMySpec.AgentTasks.QaStory,
      started_at: released_at,
      completed_at: DateTime.add(now, 2 * 3600, :second),
      story_id: story.id,
      component_id: nil,
      blocked_at: nil,
      blocker_resolved_at: nil,
      blocker_type: nil
    }

    cycle_time = CycleTime.story(context.scope, story, [late_completed_qa_task])

    assert cycle_time.total_seconds == 5 * 3600

    assert cycle_time.stages[:qa] == 5 * 3600,
           "a task's own completed_at past the story's promotion is not clamped to it"

    assert cycle_time.stages[:qa] <= cycle_time.total_seconds,
           "a stage's time exceeds the story's own total release-to-promotion time"
  end

  test "every stage stays within its own story's total, across every way one can run past it",
       context do
    shared_component_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    # Shape 1, a component-scoped task (no story_id of its own, matched
    # only via component_id): an ancient build task on the shared
    # component, predating both siblings' own release by a wide margin.
    ancient_agent = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, _ancient_agent} =
      TaskOwner.add_task(context.scope, ancient_agent, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "implementation_file",
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        component_id: shared_component_id,
        started_at: DateTime.add(now, -2000 * 3600, :second)
      })

    # Shape 2, sibling stories sharing that component.
    {:ok, story_a} =
      Stories.create_story(context.scope, %{
        title: "Story A: shared component, own build, QA completed late",
        description: "Combines all three shapes QA found on this issue."
      })

    {:ok, story_a} =
      story_a |> Story.changeset(%{component_id: shared_component_id}) |> CodeMySpec.Repo.update()

    {:ok, story_b} =
      Stories.create_story(context.scope, %{
        title: "Story B: shares the same component, nothing else unusual",
        description: "Its own total must differ from story A's."
      })

    {:ok, story_b} =
      story_b |> Story.changeset(%{component_id: shared_component_id}) |> CodeMySpec.Repo.update()

    agent_a_build = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, _agent_a_build} =
      TaskOwner.add_task(context.scope, agent_a_build, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "implementation_file",
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        component_id: shared_component_id,
        story_id: story_a.id,
        started_at: DateTime.add(now, -2 * 3600, :second)
      })

    # Shape 3, the story-1008 shape: a QA task stamped completed_at AFTER
    # its own story's promotion.
    agent_a_qa = Fixtures.running_agent(context.scope, role: "qa")

    {:ok, _agent_a_qa} =
      TaskOwner.add_task(context.scope, agent_a_qa, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "qa_complete",
        session_type: CodeMySpec.AgentTasks.QaStory,
        component_id: shared_component_id,
        story_id: story_a.id,
        started_at: DateTime.add(now, -5400, :second),
        completed_at: DateTime.add(now, 2 * 3600, :second)
      })

    agent_b_build = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, _agent_b_build} =
      TaskOwner.add_task(context.scope, agent_b_build, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "implementation_file",
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        component_id: shared_component_id,
        story_id: story_b.id,
        started_at: DateTime.add(now, -5 * 3600, :second)
      })

    {:ok, story_a} =
      story_a
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: now})
      |> CodeMySpec.Repo.update()

    {:ok, story_b} =
      story_b
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: now})
      |> CodeMySpec.Repo.update()

    cycle_time_a = CycleTime.story(context.scope, story_a)
    cycle_time_b = CycleTime.story(context.scope, story_b)

    refute cycle_time_a.total_seconds == cycle_time_b.total_seconds,
           "sibling totals are pinned to the same shared component task"

    for stage <- Stage.names() do
      assert Map.get(cycle_time_a.stages, stage, 0) <= cycle_time_a.total_seconds,
             "story A's #{stage} stage exceeds its own total"

      assert Map.get(cycle_time_b.stages, stage, 0) <= cycle_time_b.total_seconds,
             "story B's #{stage} stage exceeds its own total"
    end

    # The three shapes actually fired, not just happened to stay under by
    # being empty: story A's qa stage reflects its late-completing task
    # (clamped, not dropped), and both siblings' build stages reflect the
    # shared ancient task (clamped, not dropped).
    assert cycle_time_a.stages[:qa] > 0
    assert cycle_time_a.stages[:build] > 0
    assert cycle_time_b.stages[:build] > 0
  end
end
