defmodule CodeMySpecSpex.Story124.Criterion5257Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5257 — Completing an incomplete step is reflected on re-render.

  Setup is idempotent: completing a previously-incomplete step and
  re-mounting the page shows the newly-completed step as checked, with
  the inline prompt removed.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Setup is idempotent" do
    scenario "completing an incomplete step is reflected on re-render" do
      given_ "all steps except CodemyspecDeps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(
          context.scope,
          ProjectSetup.setup_steps() -- [Setup.CodemyspecDeps]
        )

        {:ok, context}
      end

      given_ "developer has viewed the page with CodemyspecDeps incomplete", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        html = render(view)
        assert html =~ "Project Setup (12/13)"
        assert html =~ step_prompt_heading(Setup.CodemyspecDeps, context.scope)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "developer satisfies CodemyspecDeps and re-mounts the page", context do
        Fixtures.satisfy_setup_steps(context.scope, [Setup.CodemyspecDeps])

        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the progress header reports all steps done", context do
        assert render(context.view) =~ "Project Setup (13/13)"
        {:ok, context}
      end

      and_ "CodemyspecDeps no longer shows its inline prompt", context do
        refute render(context.view) =~ step_prompt_heading(Setup.CodemyspecDeps, context.scope)
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
