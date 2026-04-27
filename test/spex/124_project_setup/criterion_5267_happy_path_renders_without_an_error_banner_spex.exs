defmodule CodeMySpecSpex.Story124.Criterion5267Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5267 — Happy path renders without an error banner.

  Step command errors propagate to the caller. With every step
  satisfied, no `[data-role=setup-error]` banner is rendered.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Step command errors propagate to the caller" do
    scenario "happy path renders without error banner" do
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

      then_ "no setup-error banner is rendered", context do
        refute has_element?(context.view, "[data-role=setup-error]")
        {:ok, context}
      end
    end
  end
end
