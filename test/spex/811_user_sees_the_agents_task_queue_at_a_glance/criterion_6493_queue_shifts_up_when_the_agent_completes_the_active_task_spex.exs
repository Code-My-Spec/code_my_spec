defmodule CodeMySpecSpex.Story811.Criterion6493Spex do
  @moduledoc """
  Story 811 — User sees the agent's task queue at a glance
  Criterion 6493 — Queue shifts up when the agent completes the
  active task.

  The view updates in place as the agent advances — Sam doesn't
  refresh. When the active task completes (the underlying
  requirement becomes satisfied) the next queued task takes its
  place and the rest shift up. LiveView's PubSub plumbing carries
  this propagation.

  Surface: `CodeMySpecWeb.AppLive.TaskQueue` LiveView at `/app/tasks`.
  Spec captures the rendered head, advances state by satisfying the
  current top requirement, and asserts the view re-renders with the
  next requirement promoted — without a manual reload.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.{Fixtures, ProjectStateFixtures}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Queue shifts up when the agent completes the active task" do
    scenario "completing the active task promotes the next queued task without refresh" do
      given_ "Sam has the task queue open with an active task", context do
        {:ok, view, html} = live(context.conn, "/app/projects/#{context.project.name}/tasks")
        {:ok, Map.merge(context, %{view: view, initial_html: html})}
      end

      and_ "the initial active task is captured", context do
        # Pull the displayed active-task identifier out of the rendered
        # HTML so we can later assert it's no longer the head. There is
        # always an active task at the head on a fresh queue — match it
        # directly so a missing head fails the spec here.
        [_, initial_active] =
          Regex.run(
            ~r/data-test="active-task"[^>]*data-requirement="([^"]+)"/,
            context.initial_html
          )

        {:ok, Map.put(context, :initial_active, initial_active)}
      end

      when_ "the agent satisfies the active task by completing its underlying requirement",
            context do
        # The natural fresh-project head is `project_setup` — satisfy it
        # fully via the same fixture the rest of the test suite uses,
        # so it ACTUALLY clears the requirement.
        ProjectStateFixtures.apply_project_setup_steps(context)

        # `apply_project_setup_steps` writes files + syncs into the
        # Files table but doesn't fire the watcher event the LiveView
        # subscribes to. Synthesize one watcher event so the
        # `"project:<id>:watcher"` broadcast triggers re-render.
        {:ok, _} = Fixtures.notify_file_changed(context.scope, "CLAUDE.md")

        # PubSub fan-out is async; give the LiveView a beat to process.
        :timer.sleep(50)

        {:ok, context}
      end

      then_ "the view re-renders without a manual reload", context do
        rerendered = render(context.view)

        assert rerendered != context.initial_html,
               "expected the LiveView to re-render after the active task completed; HTML unchanged"

        {:ok, Map.put(context, :rerendered, rerendered)}
      end

      then_ "the previously active task is no longer the head", context do
        refute context.rerendered =~
                 ~r/data-test="active-task"[^>]*data-requirement="#{Regex.escape(context.initial_active)}"/,
               "expected the previously active task (#{context.initial_active}) to no longer be at the head"

        {:ok, context}
      end
    end
  end
end
