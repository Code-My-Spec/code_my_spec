defmodule CodeMySpecSpex.Story124.Rule6ErrorsPropagateSpex do
  @moduledoc """
  Story 124 — Project Setup
  Rule 6 — Step command errors propagate to the caller.

  Covers:
  - Happy path: every step's `command/2` succeeds; page renders without
    an error banner.
  - Failure path: a step's `command/2` returns `{:error, _}`; the page
    renders a visible error banner (`[data-role=setup-error]`) with the
    reason, instead of silently falling back to a degraded prompt.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.SetupFixtures.ErroringStep
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Step command errors propagate to the caller" do
    scenario "happy path renders without error banner" do
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

      then_ "no setup-error banner is rendered", context do
        refute has_element?(context.view, "[data-role=setup-error]")
        {:ok, context}
      end
    end

    scenario "step command error surfaces as a page-level error banner" do
      given_ "a stub erroring step is injected into the setup step list", context do
        Fixtures.reset_setup_env(context.environment)
        original = Application.get_env(:code_my_spec, :project_setup_steps)
        Application.put_env(:code_my_spec, :project_setup_steps, [ErroringStep])

        on_exit(fn ->
          case original do
            nil -> Application.delete_env(:code_my_spec, :project_setup_steps)
            value -> Application.put_env(:code_my_spec, :project_setup_steps, value)
          end
        end)

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the setup-error banner is visible", context do
        assert has_element?(context.view, "[data-role=setup-error]")
        {:ok, context}
      end

      and_ "the banner includes the error reason", context do
        assert render(context.view) =~ ":stub_explosion"
        {:ok, context}
      end
    end
  end
end
