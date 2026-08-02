defmodule CodeMySpecSpex.Story717.Criterion6541Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress.
  Criterion 6541 — Rule: while the engineer has the requirements graph open, a
  file-watcher change to that project refreshes it in place — no reload, no
  full relayout, positions preserved.

  Surface: `CodeMySpecLocalWeb.RequirementsLive` (`:graph`) at
  `/projects/:name/requirements/graph`. The graph reaches the Sigma JS hook via
  `push_event` with `phx-update="ignore"`, so the observable refresh is a
  pushed `graph:update` event — not re-rendered DOM. We open the graph
  (`preload=true` so the first compute is synchronous), synthesize a watcher
  event through the Fixtures bridge (which broadcasts on the project's watcher
  topic), and assert the view pushes an incremental `graph:update`.

  The push is `graph:update` (a targeted merge), distinct from the initial
  `graph:ready` (full render) — that's what keeps existing node positions.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A watched file change refreshes the open graph in place" do
    scenario "a watcher event pushes an incremental graph update to the open view" do
      given_ "the engineer has the requirements graph open", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.name}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the file watcher reports a change to the project", context do
        {:ok, _result} = Fixtures.notify_file_changed(context.scope, "CLAUDE.md")
        {:ok, context}
      end

      then_ "an incremental graph:update is pushed to the open view (no reload)",
            context do
        # Generous timeout: the LiveView debounces 750ms then recomputes async.
        assert_push_event(context.view, "graph:update", %{data: data}, 3_000)

        assert is_map(data),
               "expected graph:update to carry the recomputed graph, got: #{inspect(data)}"

        {:ok, context}
      end
    end
  end
end
