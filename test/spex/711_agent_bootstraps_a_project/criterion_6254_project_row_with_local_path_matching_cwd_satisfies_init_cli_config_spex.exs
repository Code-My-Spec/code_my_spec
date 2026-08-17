defmodule CodeMySpecSpex.Story711.Criterion6254Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6254 — Project row with local_path matching cwd satisfies Init.CliConfig.

  When the local DB contains a `Project` row whose `local_path` equals
  the working directory and the engineer opens the CliConfig init step's
  per-step page, the page renders the step with the success ("Done")
  badge.

  Surface: `InitLive` at `/projects/:project_name/init/cli_config`. The
  active project in `setup_active_project` is created with
  `local_path: stub_dir`, giving us exactly the row this contract asks
  for.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.CliConfig is satisfied by a Project row whose local_path matches the working directory" do
    scenario "Project row with local_path matching cwd renders CliConfig as Done" do
      given_ "the local DB contains a Project row whose local_path equals the working directory",
             context do
        # setup_active_project already inserted this row — assert here for clarity.
        assert context.project.local_path == context.scope.cwd,
               "expected setup_active_project to align local_path with cwd"

        {:ok, context}
      end

      when_ "the engineer opens the CliConfig per-step page", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/init/cli_config")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the step shows the Done badge", context do
        # The badge, not the page. `html =~ "badge-success"` is also true of the
        # checklist in the sidebar, which carries a green tick for every step
        # already done — so both assertions passed on a page where *this* step
        # was not done. The sidebar ticks render "✓", so asking for the
        # success badge that reads "Done" names this step's badge alone.
        assert has_element?(context.view, "span.badge-success", "Done"),
               "expected the CliConfig step's own badge to read Done, got:\n#{context.html}"

        {:ok, context}
      end
    end
  end
end
