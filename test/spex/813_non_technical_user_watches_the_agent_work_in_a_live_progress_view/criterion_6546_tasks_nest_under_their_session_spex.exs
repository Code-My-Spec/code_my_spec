defmodule CodeMySpecSpex.Story813.Criterion6546Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6546 — Rule: the screen shows a timeline of the agent's sessions
  with their tasks nested inside each session.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. The center timeline lists sessions
  (`[data-test="session"]`), each carrying nested task elements
  (`[data-test="task"]`). We seed one session with two tasks and assert
  both tasks render *inside* the session element.

  A session is only shown once it has activity, so the fixture sets
  `updated_at` after `inserted_at` (see criterion 6548 for the
  no-activity exclusion).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Tasks nest under their session" do
    scenario "a session renders with both of its tasks nested inside it" do
      given_ "a session containing two tasks", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        session =
          Fixtures.session_fixture(context.scope, %{
            type: CodeMySpec.AgentTasks.ArchitectureDesign,
            status: :active,
            inserted_at: earlier,
            updated_at: now,
            tasks: [
              %{
                id: Ecto.UUID.generate(),
                status: :completed,
                requirement_name: "architecture_designed",
                session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
                project_id: project_id,
                started_at: earlier,
                completed_at: now
              },
              %{
                id: Ecto.UUID.generate(),
                status: :active,
                requirement_name: "architecture_designed",
                session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
                project_id: project_id,
                started_at: now
              }
            ]
          })

        {:ok, Map.put(context, :session, session)}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the session renders with both tasks nested inside it", context do
        [task_a, task_b] = context.session.tasks

        assert has_element?(
                 context.view,
                 "[data-test='session'][data-session-id='#{context.session.id}']"
               ),
               "expected the session to render in the timeline"

        assert has_element?(
                 context.view,
                 "[data-session-id='#{context.session.id}'] [data-test='task'][data-task-id='#{task_a.id}']"
               ),
               "expected the first task nested inside the session"

        assert has_element?(
                 context.view,
                 "[data-session-id='#{context.session.id}'] [data-test='task'][data-task-id='#{task_b.id}']"
               ),
               "expected the second task nested inside the session"

        {:ok, context}
      end
    end
  end
end
