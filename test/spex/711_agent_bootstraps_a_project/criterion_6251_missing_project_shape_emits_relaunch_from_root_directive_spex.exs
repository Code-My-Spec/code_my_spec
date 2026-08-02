defmodule CodeMySpecSpex.Story711.Criterion6251Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6251 — Missing project shape emits relaunch-from-root directive.

  When the engineer opens the PhoenixProject init step's per-step page
  against a working directory that lacks `mix.exs`, the page:
    1. Renders the step with a "Not done" badge.
    2. Surfaces a per-step prompt that tells the user to quit and relaunch
       Claude Code from the project root.
    3. Names the working directory the harness attached to (so the user
       can see what went wrong).

  Surface: `InitLive` at `/projects/:project_name/init/phoenix_project`.
  Pure filesystem + string output — no shell outs, no cassette.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.PhoenixProject requires mix.exs + lib/ + config/ in cwd; otherwise emits relaunch guidance" do
    scenario "Missing project shape emits relaunch-from-root directive on the per-step page" do
      given_ "the working directory has no mix.exs", context do
        # Establish the full shape first, then take mix.exs away. Removing it
        # from a working directory that never had the shape would fail the check
        # for a reason this scenario is not about.
        CodeMySpecSpex.Fixtures.add_phoenix_project_shape(context.scope)
        CodeMySpecSpex.Fixtures.remove_mix_exs(context.scope)
        {:ok, context}
      end

      when_ "the engineer opens the PhoenixProject per-step page", context do
        {:ok, view, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.name}/init/phoenix_project"
          )

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the step shows the Not done badge", context do
        assert context.html =~ "badge-warning",
               "expected the not-done badge on the PhoenixProject per-step page, got:\n#{context.html}"

        {:ok, context}
      end

      and_ "the per-step prompt tells the user to quit and relaunch Claude Code from the project root",
           context do
        prompt_text =
          context.view
          |> element(~s|pre|)
          |> render()

        assert prompt_text =~ ~r/re-?launch/i,
               "expected prompt to mention relaunching, got:\n#{prompt_text}"

        assert prompt_text =~ ~r/project root/i,
               "expected prompt to mention project root, got:\n#{prompt_text}"

        {:ok, Map.put(context, :prompt_text, prompt_text)}
      end

      and_ "the per-step prompt names the working directory the harness attached to",
           context do
        assert String.contains?(context.prompt_text, context.scope.cwd),
               "expected prompt to name the cwd `#{context.scope.cwd}`, got:\n#{context.prompt_text}"

        {:ok, context}
      end
    end
  end
end
