defmodule CodeMySpecSpex.Story124.Criterion5261Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5261 — Every step valid renders 12/12 with no incomplete prompts.

  Completion is gated by every step evaluating `{:ok, :valid}`. When
  every step is satisfied, the page reports 12/12 and renders no inline
  prompt body.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Completion is gated by every step evaluating valid" do
    scenario "every step valid renders 12/12 with no incomplete prompt bodies" do
      given_ "every setup step is satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.satisfy_setup_steps(context.scope, Fixtures.setup_steps())
        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the progress header reports all steps done", context do
        assert render(context.view) =~ "Project Setup (12/12)"
        {:ok, context}
      end

      and_ "no step's inline prompt heading is rendered", context do
        html = render(context.view)

        for mod <- Fixtures.setup_steps() do
          heading = step_prompt_heading(mod, context.scope)

          refute html =~ heading,
                 "expected inline prompt heading #{inspect(heading)} to be absent for completed #{inspect(mod)}"
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
