defmodule CodeMySpecSpex.Story711.Criterion6250Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6250 — Phoenix project shape in cwd satisfies Init.PhoenixProject.

  When the engineer opens the PhoenixProject init step's per-step page
  against a working directory that contains `mix.exs`, `lib/`, AND
  `config/`, the page renders the step with the success ("Done") badge.

  Surface: `InitLive` at `/projects/:project_name/init/phoenix_project`.
  Pure filesystem check — no shell outs, no cassette.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.PhoenixProject requires mix.exs + lib/ + config/ in cwd; otherwise emits relaunch guidance" do
    scenario "Phoenix project shape in cwd is rendered as Done on the per-step page" do
      given_ "the working directory contains mix.exs, lib/, and config/",
             context do
        CodeMySpecSpex.Fixtures.add_phoenix_project_shape(context.scope)
        # setup_active_project already seeded mix.exs and lib/
        {:ok, context}
      end

      when_ "the engineer opens the PhoenixProject per-step page", context do
        {:ok, view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/init/phoenix_project"
          )

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the step shows the Done badge", context do
        # The badge, not the page. `html =~ "badge-success"` is also true of the
        # checklist in the sidebar, which carries a green tick for every step
        # already done — so both assertions passed on a page where *this* step
        # was not done. The sidebar ticks render "✓", so asking for the
        # success badge that reads "Done" names this step's badge alone.
        assert has_element?(context.view, "span.badge-success", "Done"),
               "expected the PhoenixProject step's own badge to read Done, got:\n#{context.html}"

        {:ok, context}
      end
    end
  end
end
