defmodule CodeMySpecSpex.Story124.Rule1IdempotentSpex do
  @moduledoc """
  Story 124 — Project Setup
  Rule 1 — Setup is idempotent: re-running never undoes completed work.

  Covers:
  - Fully-configured project renders every step checked.
  - Completing an incomplete step is reflected on re-render.

  Surface: `/projects/:project_name/requirements/project_setup` — the
  `RequirementsLive :show` page, which (per session decision) renders
  `ProjectSetup.command/2` output directly. See
  `.code_my_spec/issues/project-setup/specs.md`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Setup is idempotent" do
    scenario "fully-configured project renders every step checked" do
      given_ "every setup step is satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.satisfy_setup_steps(context.environment, ProjectSetup.setup_steps())
        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the progress header reports all steps done", context do
        assert render(context.view) =~ "Project Setup (13/13)"
        {:ok, context}
      end

      and_ "every step name is rendered", context do
        html = render(context.view)

        for mod <- ProjectSetup.setup_steps() do
          assert html =~ ProjectSetup.step_name(mod),
                 "expected #{ProjectSetup.step_name(mod)} to appear in the rendered page"
        end

        {:ok, context}
      end

      and_ "no incomplete step's inline prompt is rendered", context do
        html = render(context.view)

        for mod <- ProjectSetup.setup_steps() do
          heading = step_prompt_heading(mod, context.scope)

          refute html =~ heading,
                 "expected inline prompt heading #{inspect(heading)} to be absent when step is done"
        end

        {:ok, context}
      end
    end

    scenario "completing an incomplete step is reflected on re-render" do
      given_ "all steps except CodemyspecDeps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(
          context.environment,
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
        Fixtures.satisfy_setup_steps(context.environment, [Setup.CodemyspecDeps])

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

  # Extracts the h1 heading line from a step module's command prompt.
  # Used to assert presence/absence of the step's inline prompt body
  # in rendered HTML — done steps drop their prompt, incomplete steps
  # keep it.
  defp step_prompt_heading(mod, scope) do
    {:ok, prompt} = mod.command(scope, %{})

    prompt
    |> String.split("\n", trim: true)
    |> Enum.find(fn line -> String.starts_with?(line, "# ") end)
    |> String.replace_prefix("# ", "")
  end
end
