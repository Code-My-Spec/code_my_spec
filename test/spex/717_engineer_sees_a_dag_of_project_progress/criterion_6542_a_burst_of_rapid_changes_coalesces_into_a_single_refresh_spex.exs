defmodule CodeMySpecSpex.Story717.Criterion6542Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress.
  Criterion 6542 — Rule: a burst of rapid file-watcher changes coalesces into a
  single graph refresh (trailing-edge debounce), so the view doesn't thrash
  while the engineer saves repeatedly.

  Surface: same as 6541. Open the graph, fire several watcher events in quick
  succession, and assert exactly one graph:update lands once they settle.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A burst of rapid changes coalesces into a single refresh" do
    scenario "several watcher events in quick succession push only one graph:update" do
      given_ "the engineer has the requirements graph open", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :view, view)}
      end

      when_ "several file-watcher changes arrive in quick succession", context do
        {:ok, _} = Fixtures.notify_file_changed(context.scope, "CLAUDE.md")
        {:ok, _} = Fixtures.notify_file_changed(context.scope, "README.md")
        {:ok, _} = Fixtures.notify_file_changed(context.scope, "AGENTS.md")
        {:ok, context}
      end

      then_ "exactly one graph:update is pushed once the changes settle", context do
        assert_push_event(context.view, "graph:update", %{data: _}, 3_000)

        # Trailing-edge debounce coalesced the burst — there is no second update.
        refute_push_event(context.view, "graph:update", 900)

        {:ok, context}
      end
    end
  end
end
