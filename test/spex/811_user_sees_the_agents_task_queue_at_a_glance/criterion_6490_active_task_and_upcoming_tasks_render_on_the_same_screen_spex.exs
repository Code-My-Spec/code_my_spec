defmodule CodeMySpecSpex.Story811.Criterion6490Spex do
  @moduledoc """
  Story 811 — User sees the agent's task queue at a glance
  Criterion 6490 — Active task and upcoming tasks render on the
  same screen.

  Sam needs single-glance visibility of what the agent is on AND
  what's next, without drilling into the active task and bouncing
  back out for the queue. The Task Queue surface shows both
  groupings in one rendered view.

  Surface: `CodeMySpecWeb.AppLive.TaskQueue` LiveView at `/app/tasks`,
  driven from Phoenix.LiveViewTest. Spec asserts the rendered HTML
  contains both an active-task region and an upcoming-tasks region
  with at least one item each.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active task and upcoming tasks render on the same screen" do
    scenario "the queue view shows the active task and the upcoming list together" do
      given_ :fully_satisfied_project

      and_ "two additional component-linked stories are added", context do
        # Fully-satisfied baseline returns 0 actionable. Story-level
        # requirements are gated on `architecture_designed`, so
        # unlinked stories never surface story-level work. Link the
        # two new stories to the existing satisfied component — this
        # keeps architecture green AND surfaces two story-level
        # `three_amigos_complete` requirements (the next gate after
        # component_linked) concurrently.
        StoryHelpers.create_and_link(
          context.scope,
          context.component.module_name,
          title: "Extra A",
          description: "Story A"
        )

        StoryHelpers.create_and_link(
          context.scope,
          context.component.module_name,
          title: "Extra B",
          description: "Story B"
        )

        actionable = Fixtures.next_actionable_requirements(context.scope)

        assert length(actionable) >= 2,
               """
               Fixture should produce ≥2 concurrent actionable for the active+upcoming
               contract, got #{length(actionable)}:

                 #{Enum.map_join(actionable, "\n  ", fn r -> "#{r.name}/#{r.entity_type}" end)}
               """

        {:ok, context}
      end

      when_ "Sam opens the task queue view", context do
        {:ok, view, html} = live(context.conn, "/app/projects/#{context.project.id}/tasks")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the active task region is visible", context do
        assert context.html =~ ~r/data-test="active-task"/,
               "expected an active-task region (data-test=\"active-task\"); rendered: #{String.slice(context.html, 0, 500)}"

        {:ok, context}
      end

      then_ "the upcoming tasks region is visible with at least one item",
            context do
        assert context.html =~ ~r/data-test="upcoming-tasks"/,
               "expected an upcoming-tasks region (data-test=\"upcoming-tasks\"); rendered: #{String.slice(context.html, 0, 500)}"

        assert context.html =~ ~r/data-test="upcoming-task-item"/,
               "expected at least one upcoming-task-item entry; rendered: #{String.slice(context.html, 0, 500)}"

        {:ok, context}
      end

      then_ "no drill-in navigation is required to see both",
            context do
        # The contract: both regions rendered in the SAME response,
        # not behind a click. A re-render without further navigation
        # should still show both.
        rerendered = render(context.view)

        assert rerendered =~ ~r/data-test="active-task"/
        assert rerendered =~ ~r/data-test="upcoming-tasks"/

        {:ok, context}
      end
    end
  end
end
