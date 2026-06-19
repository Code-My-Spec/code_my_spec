defmodule CodeMySpecSpex.Story813.Criterion6550Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6550 — Rule (focus arm): the active session — the one a
  session-activity event names — has its current step auto-expanded: the
  last task that is not completed or cancelled.

  Liveness is event-driven, not status-derived: persisted `status ==
  :active` is unreliable (a crashed agent leaves stale `:active` tasks
  behind). We seed a working session (a completed task then a current
  in-progress task) plus another session that still carries a leftover
  `:active` task, fire the `:active` event for the working session only,
  and assert focus lands on its current step — not the leftover active
  task in the other session, and not the working session's completed task.

  Surface: `CodeMySpecLocalWeb.AgentProgressLive`. Focused task →
  `[data-test="task"][data-expanded="true"]`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active session's current step is expanded" do
    scenario "focus is the working session's last non-terminal task" do
      given_ "a working session and another session with a leftover active task",
             context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        project_id = context.scope.active_project_id

        done_id = Ecto.UUID.generate()
        current_id = Ecto.UUID.generate()
        other_id = Ecto.UUID.generate()

        working =
          Fixtures.session_fixture(context.scope, %{
            type: CodeMySpec.AgentTasks.ArchitectureDesign,
            status: :active,
            inserted_at: DateTime.add(now, -3600, :second),
            updated_at: now,
            tasks: [
              %{
                id: done_id,
                status: :completed,
                requirement_name: "architecture_designed",
                session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
                project_id: project_id,
                started_at: DateTime.add(now, -3000, :second),
                completed_at: DateTime.add(now, -2000, :second)
              },
              %{
                id: current_id,
                status: :active,
                requirement_name: "code_generation",
                session_type: CodeMySpec.AgentTasks.CodeGeneration,
                project_id: project_id,
                started_at: DateTime.add(now, -1000, :second)
              }
            ]
          })

        Fixtures.session_fixture(context.scope, %{
          type: CodeMySpec.AgentTasks.ProjectSetup,
          status: :active,
          inserted_at: DateTime.add(now, -7200, :second),
          updated_at: DateTime.add(now, -7000, :second),
          tasks: [
            %{
              id: other_id,
              status: :active,
              requirement_name: "project_setup",
              session_type: CodeMySpec.AgentTasks.ProjectSetup,
              project_id: project_id,
              started_at: DateTime.add(now, -7100, :second)
            }
          ]
        })

        {:ok,
         Map.merge(context, %{
           working_id: working.id,
           done_id: done_id,
           current_id: current_id,
           other_id: other_id
         })}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the working session's current step is expanded", context do
        assert has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.current_id}'][data-expanded='true']"
               ),
               "expected the working session's last non-terminal task to be expanded"

        {:ok, context}
      end

      then_ "the completed task and the other session's active task are not expanded",
            context do
        refute has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.done_id}'][data-expanded='true']"
               ),
               "expected the already-completed task not to be expanded"

        refute has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.other_id}'][data-expanded='true']"
               ),
               "expected the other session's leftover active task not to be expanded"

        {:ok, context}
      end
    end
  end
end
