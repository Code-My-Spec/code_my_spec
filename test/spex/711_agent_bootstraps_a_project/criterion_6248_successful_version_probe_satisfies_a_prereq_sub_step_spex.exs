defmodule CodeMySpecSpex.Story711.Criterion6248Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6248 — Successful version probe satisfies a prereq sub-step.

  When the engineer opens the Elixir init step's per-step page against a
  toolchain that reports Elixir 1.18 or higher via `elixir --version`,
  the page renders the step with the success ("Done") badge.

  Surface: `InitLive` at `/projects/:project_name/init/elixir`. The
  evaluate path shells out via `System.cmd`; ExCliVcr replays
  `init_elixir_pass.json` so the assertion doesn't depend on the test
  host's Elixir version.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Prereq sub-steps satisfy on a successful version-probe shell out" do
    scenario "Elixir step's per-step page shows Done when the version probe passes" do
      given_ "the active toolchain reports an Elixir version of 1.18 or higher",
             context do
        {:ok, context}
      end

      when_ "the engineer opens the Elixir per-step page", context do
        {view, html} =
          use_cmd_cassette "init_elixir_pass", record: :none do
            {:ok, view, html} =
              live(context.conn, ~p"/projects/#{context.project.name}/init/elixir")

            {view, html}
          end

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the Elixir step shows the success (Done) badge", context do
        assert context.html =~ "badge-success",
               "expected the Elixir per-step page to show a success badge, got:\n#{context.html}"

        assert context.html =~ "Done",
               "expected the Elixir per-step page to render the literal Done badge, got:\n#{context.html}"

        {:ok, context}
      end

      and_ "no per-step prompt is rendered (the step is satisfied)", context do
        refute context.html =~ "Install Elixir",
               "expected NO install-elixir prompt on a satisfied step, got:\n#{context.html}"

        refute context.view |> has_element?(~s|pre|),
               "expected NO <pre> prompt block on a satisfied step"

        {:ok, context}
      end
    end
  end
end
