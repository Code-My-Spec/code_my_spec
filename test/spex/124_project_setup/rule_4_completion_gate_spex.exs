defmodule CodeMySpecSpex.Story124.Rule4CompletionGateSpex do
  @moduledoc """
  Story 124 — Project Setup
  Rule 4 — Completion is gated by every step evaluating `{:ok, :valid}`.

  Covers:
  - Every step valid — page shows all done.
  - One step incomplete — that step is unchecked and its prompt inlined.
  - Multiple steps incomplete — all are listed as unchecked with prompts.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Completion is gated by every step evaluating valid" do
    scenario "every step valid renders 13/13 with no incomplete prompt bodies" do
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

      and_ "no step's inline prompt heading is rendered", context do
        html = render(context.view)

        for mod <- ProjectSetup.setup_steps() do
          heading = step_prompt_heading(mod, context.scope)

          refute html =~ heading,
                 "expected inline prompt heading #{inspect(heading)} to be absent for completed #{inspect(mod)}"
        end

        {:ok, context}
      end
    end

    scenario "one incomplete step is named and its prompt inlined" do
      given_ "every step is satisfied except Rules", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(
          context.environment,
          ProjectSetup.setup_steps() -- [Setup.Rules]
        )

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the progress header reports 12/13", context do
        assert render(context.view) =~ "Project Setup (12/13)"
        {:ok, context}
      end

      and_ "Rules is the only step whose inline prompt heading is rendered", context do
        html = render(context.view)
        rules_heading = step_prompt_heading(Setup.Rules, context.scope)

        assert html =~ rules_heading,
               "expected Rules inline prompt heading #{inspect(rules_heading)} to be rendered"

        for mod <- ProjectSetup.setup_steps() -- [Setup.Rules] do
          heading = step_prompt_heading(mod, context.scope)

          refute html =~ heading,
                 "expected #{inspect(mod)} prompt heading #{inspect(heading)} to be absent"
        end

        {:ok, context}
      end
    end

    scenario "multiple incomplete steps each render with their prompts" do
      incomplete = [Setup.Rules, Setup.CredoChecks, Setup.ClaudeMd]

      given_ "Rules, CredoChecks, and ClaudeMd are unsatisfied; others are satisfied", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(
          context.environment,
          ProjectSetup.setup_steps() -- incomplete
        )

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the progress header reports 10/13", context do
        assert render(context.view) =~ "Project Setup (10/13)"
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

        for mod <- ProjectSetup.setup_steps() -- incomplete do
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
