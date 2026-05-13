defmodule CodeMySpecSpex.Story124.Criterion5263Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5263 — Multiple incomplete steps are named and their prompts inlined.

  Completion is gated per-step. With three steps incomplete, the header
  reports 9/12 and each incomplete step's inline prompt heading is
  rendered.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Completion is gated by every step evaluating valid" do
    scenario "multiple incomplete steps each render with their prompts" do
      incomplete = [Fixtures.find_setup_step("rules"), Fixtures.find_setup_step("credo_checks"), Fixtures.find_setup_step("claude_md")]

      given_ "Rules, CredoChecks, and ClaudeMd are unsatisfied; others are satisfied", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(
          context.scope,
          Fixtures.setup_steps() -- incomplete
        )

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the progress header reports 9/12", context do
        assert render(context.view) =~ "Project Setup (9/12)"
        {:ok, context}
      end

      and_ "each incomplete step's prompt heading is rendered", context do
        html = render(context.view)

        for mod <- incomplete do
          heading = step_prompt_heading(mod, context.scope)

          assert html =~ heading,
                 "expected inline prompt heading #{inspect(heading)} to be rendered for #{inspect(mod)}"
        end

        {:ok, context}
      end

      and_ "completed steps do not render their prompt headings", context do
        html = render(context.view)

        for mod <- Fixtures.setup_steps() -- incomplete do
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
