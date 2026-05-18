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
        File.mkdir_p!(Path.join(context.scope.cwd, "config"))
        # setup_active_project already seeded mix.exs and lib/
        {:ok, context}
      end

      when_ "the engineer opens the PhoenixProject per-step page", context do
        {:ok, _view, html} =
          live(
            context.conn,
            ~p"/projects/#{context.project.name}/init/phoenix_project"
          )

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the step shows the Done badge", context do
        assert context.html =~ "badge-success",
               "expected the PhoenixProject per-step page to show a success badge, got:\n#{context.html}"

        assert context.html =~ "Done",
               "expected the PhoenixProject per-step page to render the literal Done badge, got:\n#{context.html}"

        {:ok, context}
      end
    end
  end
end
