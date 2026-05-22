defmodule CodeMySpecSpex.Story811.Criterion6491Spex do
  @moduledoc """
  Story 811 — User sees the agent's task queue at a glance
  Criterion 6491 — Empty queue shows an explicit "nothing to do"
  state.

  When every requirement is satisfied (or there's nothing to schedule),
  the queue view should surface the empty state as a first-class
  result — not a blank region that looks like a render error.

  Surface: `CodeMySpecWeb.AppLive.TaskQueue` LiveView at `/app/tasks`
  driven with a fully-satisfied project (no actionable requirements).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Empty queue shows an explicit nothing-to-do state" do
    scenario "the view shows an empty state with no active task and no queued tasks" do
      given_ :fully_satisfied_project

      when_ "Sam opens the task queue view", context do
        {:ok, view, html} = live(context.conn, "/projects/#{context.project.name}/tasks")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the view renders the empty-queue state", context do
        assert context.html =~ ~r/data-test="empty-queue"/,
               "expected an empty-queue region (data-test=\"empty-queue\"); rendered: #{String.slice(context.html, 0, 500)}"

        {:ok, context}
      end

      then_ "no active task region is rendered", context do
        refute context.html =~ ~r/data-test="active-task"/,
               "expected no active-task region in the empty state; rendered: #{String.slice(context.html, 0, 500)}"

        {:ok, context}
      end

      then_ "no upcoming task items are rendered", context do
        refute context.html =~ ~r/data-test="upcoming-task-item"/,
               "expected no upcoming-task-item entries in the empty state; rendered: #{String.slice(context.html, 0, 500)}"

        {:ok, context}
      end
    end
  end
end
