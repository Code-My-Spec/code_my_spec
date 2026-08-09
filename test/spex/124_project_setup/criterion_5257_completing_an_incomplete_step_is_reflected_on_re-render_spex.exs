defmodule CodeMySpecSpex.Story124.Criterion5257Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5257 — Completing an incomplete step is reflected on re-render.

  Setup is idempotent: completing a previously-incomplete step and
  re-mounting the page shows the newly-completed step as checked, with
  the inline prompt removed.

  Surface: `/app/projects/:project_id/setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Setup is idempotent" do
    scenario "completing an incomplete step is reflected on re-render" do
      given_ "all steps except CodemyspecDeps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(
          context.scope,
          Fixtures.setup_steps() -- [Fixtures.find_setup_step("codemyspec_deps")]
        )

        {:ok, context}
      end

      given_ "developer has viewed the page with CodemyspecDeps incomplete", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/setup")

        html = render(view)
        assert html =~ "Project Setup (11/12)"
        assert html =~ step_prompt_heading(Fixtures.find_setup_step("codemyspec_deps"), context.scope)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "developer satisfies CodemyspecDeps and re-mounts the page", context do
        Fixtures.satisfy_setup_steps(context.scope, [Fixtures.find_setup_step("codemyspec_deps")])

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the progress header reports all steps done", context do
        assert render(context.view) =~ "Project Setup (12/12)"
        {:ok, context}
      end

      and_ "CodemyspecDeps no longer shows its inline prompt", context do
        refute render(context.view) =~ step_prompt_heading(Fixtures.find_setup_step("codemyspec_deps"), context.scope)
        {:ok, context}
      end
    end
  end

  defp step_prompt_heading(mod, scope) do
    {:ok, prompt} = mod.command(scope, %{})

    prompt
    |> String.split("\n", trim: true)
    |> Enum.find(fn line -> String.starts_with?(line, "# ") end)
    |> String.replace_prefix("# ", "")
  end
end
