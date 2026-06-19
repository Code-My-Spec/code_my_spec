defmodule CodeMySpecSpex.Story813.Criterion6557Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6557 — Rule: a session with no tasks is hidden from the timeline.

  Surface: `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. We seed a task-less session alongside
  a session that has tasks (anchor), open the timeline, and assert the
  task-less session does not render while the one with tasks does.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Empty session is hidden" do
    scenario "a session with no tasks does not appear on the timeline" do
      given_ "a task-less session and a session with a task both exist", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        empty =
          Fixtures.session_fixture(context.scope, %{
            type: CodeMySpec.AgentTasks.ArchitectureDesign,
            status: :active,
            inserted_at: earlier,
            updated_at: now,
            tasks: []
          })

        populated =
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

        {:ok, Map.merge(context, %{empty: empty, populated: populated})}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the task-less session is absent while the one with tasks renders", context do
        assert has_element?(
                 context.view,
                 "[data-test='session'][data-session-id='#{context.populated.id}']"
               ),
               "expected the session with tasks to render (anchor)"

        refute has_element?(
                 context.view,
                 "[data-test='session'][data-session-id='#{context.empty.id}']"
               ),
               "expected the task-less session to be hidden from the timeline"

        {:ok, context}
      end
    end
  end
end
