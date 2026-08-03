defmodule CodeMySpecSpex.Story813.Criterion6555Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6555 — Rule (fallback arm): task types with no curated help
  content show a generic explanation.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`, backed by `CodeMySpec.TaskHelp`. No
  help content file is written for the focused task's type, so `TaskHelp`
  finds nothing and the view renders the generic explanation rather than a
  curated body or video.

  Contract: `[data-test="task-help-generic"]` marks the fallback; no
  `[data-test="task-help-video"]` is present.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Non-major task falls back to a generic explanation" do
    scenario "a task type without curated content shows the generic explanation" do
      given_ "an active task whose type has no curated help content", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        task_id = Ecto.UUID.generate()

        session =
          Fixtures.session_fixture(context.scope, %{
            type: CodeMySpec.AgentTasks.ContextSpec,
            status: :active,
            inserted_at: earlier,
            updated_at: now,
            tasks: [
              %{
                id: task_id,
                status: :active,
                requirement_name: "spec_file",
                session_type: CodeMySpec.AgentTasks.ContextSpec,
                project_id: project_id,
                started_at: earlier
              }
            ]
          })

        {:ok, Map.merge(context, %{task_id: task_id, session_id: session.id})}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the help pane shows the generic explanation and no video", context do
        assert has_element?(context.view, "[data-test='task-help-generic']"),
               "expected the generic help explanation for a task type with no curated content"

        refute has_element?(context.view, "[data-test='task-help-video']"),
               "expected no curated video for a task type with no content file"

        {:ok, context}
      end
    end
  end
end
