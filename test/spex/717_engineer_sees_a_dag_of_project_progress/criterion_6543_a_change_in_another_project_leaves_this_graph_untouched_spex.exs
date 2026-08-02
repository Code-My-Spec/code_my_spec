defmodule CodeMySpecSpex.Story717.Criterion6543Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress.
  Criterion 6543 — Rule (failure path): a watcher change in a DIFFERENT project
  never refreshes this view. The graph subscribes only to its own project's
  watcher topic, so a sibling project's activity is invisible to it.

  Surface: same as 6541. Open the graph for one project, fire a watcher event
  scoped to a second project, and assert no graph:update arrives here.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A change in another project leaves this graph untouched" do
    scenario "a watcher event scoped to a different project pushes no update here" do
      given_ "the engineer has the requirements graph open for one project", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.name}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the file watcher reports a change to a different project", context do
        # A second project with its own id → its watcher broadcasts on a
        # different topic ("project:<other_id>:watcher") this view never joined.
        other_project =
          Fixtures.project_fixture(context.scope,
            account_id: context.account.id,
            local_path: Path.join(System.tmp_dir!(), "spex-other-#{System.unique_integer([:positive])}"),
            client_user_id: context.user.id
          )

        other_scope =
          context.scope
          |> Map.put(:active_project, other_project)
          |> Map.put(:active_project_id, other_project.id)

        {:ok, _} = Fixtures.notify_file_changed(other_scope, "CLAUDE.md")

        {:ok, context}
      end

      then_ "no graph update is pushed to this view", context do
        # Well past the 750ms debounce — a same-project change would have landed.
        refute_push_event(context.view, "graph:update", 1_500)

        {:ok, context}
      end
    end
  end
end
