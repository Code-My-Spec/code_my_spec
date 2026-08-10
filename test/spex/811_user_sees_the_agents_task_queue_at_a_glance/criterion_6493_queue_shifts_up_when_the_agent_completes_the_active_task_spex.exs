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
        {:ok, view, html} = live(context.conn, "/app/projects/#{context.project.id}/tasks")
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
        # Satisfy whatever is actually at the head, which is
        # `personas_complete` — `setup_active_project` already leaves
        # `project_setup` behind it. Completing a requirement that is not the
        # head leaves the head where it is, so this asserted nothing.
        context = ProjectStateFixtures.apply_persona(context)

        # `apply_persona` writes the two files into the environment but nothing
        # syncs them, and `PersonasChecker` reads synced `Files` rows — so the
        # requirement stays unsatisfied until these land. Each call also fires
        # the `"project:<id>:watcher"` broadcast the LiveView re-renders on,
        # which is why the file the spec syncs has to be one that matters.
        for path <- [
              Fixtures.persona_summary_path(context.persona_slug),
              Fixtures.persona_sources_path(context.persona_slug)
            ] do
          {:ok, _} = Fixtures.notify_file_changed(context.scope, path)
        end

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
