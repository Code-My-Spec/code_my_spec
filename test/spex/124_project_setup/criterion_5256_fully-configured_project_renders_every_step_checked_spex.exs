defmodule CodeMySpecSpex.Story124.Criterion5256Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5256 — Fully-configured project renders every step checked.

  Setup is idempotent: re-running on a project where every step is
  already satisfied renders all 13 steps as checked, with no inline
  prompts.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Setup is idempotent" do
    scenario "fully-configured project renders every step checked" do
      given_ "every setup step is satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.satisfy_setup_steps(context.scope, ProjectSetup.setup_steps())
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
  end

  defp step_prompt_heading(mod, scope) do
    {:ok, prompt} = mod.command(scope, %{})

    prompt
    |> String.split("\n", trim: true)
    |> Enum.find(fn line -> String.starts_with?(line, "# ") end)
    |> String.replace_prefix("# ", "")
  end
end
