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

  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active task and upcoming tasks render on the same screen" do
    scenario "the queue view shows the active task and the upcoming list together" do
      given_ :fully_satisfied_project

      and_ "the component's implementation AND test files are removed",
           context do
        # Fully-satisfied baseline returns 0 actionable. Remove the
        # component's `implementation_file` AND `test_file` artifacts to
        # regress two independent component-level requirements concurrently
        # — yields the multi-actionable state the view contract assumes
        # (active + ≥1 upcoming).
        impl_path =
          "lib/some_name/" <> Macro.underscore(context.component.module_name) <> ".ex"

        test_path =
          "test/some_name/" <> Macro.underscore(context.component.module_name) <> "_test.exs"

        :ok = Environments.delete_file(context.environment, impl_path)
        :ok = Environments.delete_file(context.environment, test_path)
        {:ok, _} = Fixtures.notify_file_changed(context.scope, impl_path)
        {:ok, _} = Fixtures.notify_file_changed(context.scope, test_path)

        actionable = RequirementGraph.next_actionable(context.scope)

        if length(actionable) < 2 do
          flunk("""
          Fixture should produce ≥2 concurrent actionable requirements for the
          active+upcoming view contract, got #{length(actionable)}:

            #{Enum.map_join(actionable, "\n  ", fn r -> "#{r.name}/#{r.entity_type}" end)}
          """)
        end

        {:ok, context}
      end

      when_ "Sam opens the task queue view", context do
        {:ok, view, html} = live(context.conn, "/projects/#{context.project.name}/tasks")
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
