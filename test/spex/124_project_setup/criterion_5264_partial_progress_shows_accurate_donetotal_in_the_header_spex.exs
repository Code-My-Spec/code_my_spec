defmodule CodeMySpecSpex.Story124.Criterion5264Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5264 — Partial progress shows accurate done/total in the header.

  Progress is visible in the prompt: with three steps explicitly
  satisfied (and TestSupportNamespace passing by default), the header
  reads `Project Setup (4/12)`.

  TestSupportNamespace passes by default — see fixture invariants in
  `test/support/fixtures/setup_fixtures.ex`.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Progress is visible in the prompt" do
    scenario "partial progress shows accurate (done/total) header" do
      # Fixture satisfies 3 steps explicitly. TestSupportNamespace passes
      # by default (missing conn_case.ex / data_case.ex), giving 4/12.
      given_ "three specific steps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(context.scope, [
          Fixtures.find_setup_step("application_in_web"),
          Fixtures.find_setup_step("codemyspec_deps"),
          Fixtures.find_setup_step("compilers")
        ])

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the header reads Project Setup (4/12)", context do
        assert render(context.view) =~ "Project Setup (4/12)"
        {:ok, context}
      end
    end
  end
end
