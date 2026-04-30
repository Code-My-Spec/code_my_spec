defmodule CodeMySpecSpex.Story124.Criterion5259Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5259 — Reverse-order completion still lands on 12/12.

  Order of step completion is not enforced. Satisfying every step in
  reverse declaration order still produces the fully-complete header.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Order of step completion is not enforced" do
    scenario "reverse-order completion still lands on 12/12" do
      given_ "no steps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        {:ok, context}
      end

      when_ "developer satisfies every step in reverse declaration order", context do
        reversed = Enum.reverse(ProjectSetup.setup_steps())

        for mod <- reversed do
          Fixtures.satisfy_setup_steps(context.scope, [mod])
        end

        {:ok, context}
      end

      then_ "the project setup page shows all steps done", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        assert render(view) =~ "Project Setup (12/12)"
        {:ok, Map.put(context, :view, view)}
      end
    end
  end
end
