defmodule CodeMySpecSpex.Story813.Criterion6553Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6553 — Rule: the focused task shows its artifact — the work
  product for that step.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. The auto-focused active task renders
  an artifact region. We seed a single active task and assert the expanded
  task carries `[data-test="task-artifact"]`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Focused task shows its artifact" do
    scenario "the expanded task renders its artifact region" do
      given_ "an active task that has produced an artifact", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        task_id = Ecto.UUID.generate()

        session =
          Fixtures.session_fixture(context.scope, %{
            type: CodeMySpec.AgentTasks.ArchitectureDesign,
            status: :active,
            inserted_at: earlier,
            updated_at: now,
            tasks: [
              %{
                id: task_id,
                status: :active,
                requirement_name: "architecture_designed",
                session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
                project_id: project_id,
                started_at: earlier,
                expected_files: [".code_my_spec/architecture/overview.md"]
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

      then_ "the focused task renders its artifact region", context do
        assert has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.task_id}'][data-expanded='true'] [data-test='task-artifact']"
               ),
               "expected the focused task to render its artifact"

        {:ok, context}
      end
    end
  end
end
