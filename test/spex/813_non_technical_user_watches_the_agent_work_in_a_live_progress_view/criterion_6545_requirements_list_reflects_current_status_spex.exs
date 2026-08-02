defmodule CodeMySpecSpex.Story813.Criterion6545Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6545 — Rule: the screen shows the project's requirements with
  their current status (done, in progress, or not started).

  Surface: `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. The left rail lists the project-level
  requirement milestones (project_setup, architecture_designed, …) — not
  the per-component fan-out — each with a status token. Project-level
  requirements exist for any project, so we open the view and assert a
  known milestone renders alongside a status.

  Contract:
    * `[data-test="requirements-list"]` wraps the rail.
    * Each `[data-test="requirement-row"]` carries `data-status` and a
      status token.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Requirements list reflects current status" do
    scenario "the rail renders project-level requirements with status" do
      when_ "the user opens the progress view", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.name}/progress")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the requirements rail renders project milestones with status", context do
        # The rail loads asynchronously off the LiveView process; await it.
        html = render_async(context.view)

        assert has_element?(context.view, "[data-test='requirements-list']"),
               "expected the progress view to render a requirements rail"

        assert has_element?(context.view, "[data-test='requirement-row']"),
               "expected at least one requirement row in the rail"

        assert html =~ "project_setup",
               "expected a project-level requirement milestone in the rail"

        assert html =~ ~r/done|in progress|not started/i,
               "expected each requirement row to carry a status token"

        {:ok, context}
      end
    end
  end
end
