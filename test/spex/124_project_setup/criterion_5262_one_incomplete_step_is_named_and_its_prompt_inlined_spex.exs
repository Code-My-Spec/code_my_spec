defmodule CodeMySpecSpex.Story124.Criterion5262Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5262 — One incomplete step is named and its prompt inlined.

  Completion is gated per-step. With one step incomplete, the header
  reports 11/12 and only that step's inline prompt heading is rendered.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Completion is gated by every step evaluating valid" do
    scenario "one incomplete step is named and its prompt inlined" do
      given_ "every step is satisfied except Rules", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(
          context.scope,
          Fixtures.setup_steps() -- [Fixtures.find_setup_step("rules")]
        )

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the progress header reports 11/12", context do
        assert render(context.view) =~ "Project Setup (11/12)"
        {:ok, context}
      end

      and_ "Rules is the only step whose inline prompt heading is rendered", context do
        html = render(context.view)
        rules_heading = step_prompt_heading(Fixtures.find_setup_step("rules"), context.scope)

        assert html =~ rules_heading,
               "expected Rules inline prompt heading #{inspect(rules_heading)} to be rendered"

        for mod <- Fixtures.setup_steps() -- [Fixtures.find_setup_step("rules")] do
          heading = step_prompt_heading(mod, context.scope)

          refute html =~ heading,
                 "expected #{inspect(mod)} prompt heading #{inspect(heading)} to be absent"
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
