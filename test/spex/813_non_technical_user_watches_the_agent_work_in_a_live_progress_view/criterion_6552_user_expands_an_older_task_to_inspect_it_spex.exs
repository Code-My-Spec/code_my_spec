defmodule CodeMySpecSpex.Story813.Criterion6552Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6552 — Rule: the user can scroll the timeline and expand any task
  to inspect it, overriding the auto-focus until a new task opens.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. We seed an active task (auto-expanded)
  and an older completed task (collapsed), click the older task's toggle,
  and assert the older task expands.

  Contract: each task header carries `[data-test="task-toggle"]` wired with
  `phx-click` to expand/focus that task.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "User expands an older task to inspect it" do
    scenario "clicking an older task expands it, overriding the auto-focus" do
      given_ "an active task auto-focused and an older completed task collapsed",
             context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        older = DateTime.add(now, -7200, :second)
        project_id = context.scope.active_project_id

        old_task_id = Ecto.UUID.generate()

        Fixtures.session_fixture(context.scope, %{
          type: CodeMySpec.AgentTasks.ProjectSetup,
          status: :complete,
          inserted_at: older,
          updated_at: DateTime.add(older, 60, :second),
          tasks: [
            %{
              id: old_task_id,
              status: :completed,
              requirement_name: "project_setup",
              session_type: CodeMySpec.AgentTasks.ProjectSetup,
              project_id: project_id,
              started_at: older,
              completed_at: DateTime.add(older, 60, :second)
            }
          ]
        })

        Fixtures.session_fixture(context.scope, %{
          type: CodeMySpec.AgentTasks.ArchitectureDesign,
          status: :active,
          inserted_at: earlier,
          updated_at: now,
          tasks: [
            %{
              id: Ecto.UUID.generate(),
              status: :active,
              requirement_name: "architecture_designed",
              session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
              project_id: project_id,
              started_at: earlier
            }
          ]
        })

        {:ok, Map.put(context, :old_task_id, old_task_id)}
      end

      when_ "the user expands the older task", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/progress")

        view
        |> element(
          "[data-test='task'][data-task-id='#{context.old_task_id}'] [data-test='task-toggle']"
        )
        |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the older task is now expanded", context do
        assert has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.old_task_id}'][data-expanded='true']"
               ),
               "expected the manually-opened older task to be expanded"

        {:ok, context}
      end
    end
  end
end
