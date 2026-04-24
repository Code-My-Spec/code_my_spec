defmodule CodeMySpecSpex.Story124.Rule5ProgressVisibleSpex do
  @moduledoc """
  Story 124 — Project Setup
  Rule 5 — Progress is visible in the prompt.

  The `(done/total)` header and per-step rendering communicate at a
  glance how much of setup is complete.

  Covers:
  - Partial progress (3/13) shows an accurate header.
  - Fully-complete state (13/13) shows every step checked with no
    inline prompt bodies.
  - A completed step renders as checked with no prompt body beneath.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Progress is visible in the prompt" do
    scenario "partial progress shows accurate (done/total) header" do
      # Fixture satisfies 3 steps explicitly. TestSupportNamespace passes
      # by default (missing conn_case.ex / data_case.ex), giving 4/13.
      given_ "three specific steps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(context.environment, [
          Setup.ApplicationInWeb,
          Setup.CodemyspecDeps,
          Setup.Compilers
        ])

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the header reads Project Setup (4/13)", context do
        assert render(context.view) =~ "Project Setup (4/13)"
        {:ok, context}
      end
    end

    scenario "fully complete shows 13/13 with no prompt bodies" do
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

      then_ "the header reads Project Setup (13/13)", context do
        assert render(context.view) =~ "Project Setup (13/13)"
        {:ok, context}
      end

      and_ "no incomplete prompt bodies are rendered", context do
        html = render(context.view)

        for mod <- ProjectSetup.setup_steps() do
          heading = step_prompt_heading(mod, context.scope)

          refute html =~ heading,
                 "expected inline prompt heading #{inspect(heading)} to be absent when fully complete"
        end

        {:ok, context}
      end
    end

    scenario "a completed step renders with no prompt body" do
      given_ "only ApplicationInWeb is satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.satisfy_setup_steps(context.environment, [Setup.ApplicationInWeb])
        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "ApplicationInWeb's step name is rendered", context do
        assert render(context.view) =~ ProjectSetup.step_name(Setup.ApplicationInWeb)
        {:ok, context}
      end

      and_ "ApplicationInWeb's inline prompt heading is absent", context do
        heading = step_prompt_heading(Setup.ApplicationInWeb, context.scope)

        refute render(context.view) =~ heading,
               "expected ApplicationInWeb prompt heading #{inspect(heading)} to be absent when completed"

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
