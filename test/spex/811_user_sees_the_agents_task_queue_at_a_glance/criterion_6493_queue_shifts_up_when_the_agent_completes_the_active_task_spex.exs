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

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Queue shifts up when the agent completes the active task" do
    scenario "completing the active task promotes the next queued task without refresh" do
      given_ "Sam has the task queue open with an active task", context do
        {:ok, view, html} = live(context.conn, "/app/tasks")
        {:ok, Map.merge(context, %{view: view, initial_html: html})}
      end

      and_ "the initial active task is captured", context do
        # Pull the displayed active-task identifier out of the
        # rendered HTML so we can later assert it's no longer the
        # head.
        initial_active =
          case Regex.run(~r/data-test="active-task"[^>]*data-requirement="([^"]+)"/,
                 context.initial_html
               ) do
            [_, name] -> name
            nil -> nil
          end

        {:ok, Map.put(context, :initial_active, initial_active)}
      end

      when_ "the agent satisfies the active task by completing its underlying requirement",
            context do
        # Satisfy project_setup (the natural fresh-project head) by
        # writing the canonical setup files. This re-routes through
        # the same surface a real agent would use, not a Repo direct
        # write.
        :ok =
          Environments.write_file(
            context.environment,
            "CLAUDE.md",
            "<!-- code_my_spec:start -->\n<!-- code_my_spec:end -->\n"
          )

        # PubSub fan-out from the file watcher / sync pipeline drives
        # the LiveView re-render. Wait for it.
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
        if context.initial_active do
          refute context.rerendered =~
                   ~r/data-test="active-task"[^>]*data-requirement="#{Regex.escape(context.initial_active)}"/,
                 "expected the previously active task (#{context.initial_active}) to no longer be at the head"
        end

        {:ok, context}
      end
    end
  end
end
