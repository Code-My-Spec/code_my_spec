defmodule CodeMySpecSpex.Story813.Criterion6556Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6556 — Rule: the screen updates in real time as the agent works,
  with no manual refresh.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. The LiveView subscribes to the
  project's sessions PubSub topic on mount. When a new active task starts —
  here driven through the session fixture, which (once the Sessions context
  broadcasts on task lifecycle) publishes to that topic — the open view
  re-renders to show it without a reload.

  Depends on the not-yet-built Sessions PubSub broadcast (see the story's
  architecture notes); this spec is red until that lands.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Screen updates live as the agent starts new work" do
    scenario "a newly started task appears on the open view without a reload" do
      given_ "the user is watching the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the new task is not on screen yet", context do
        new_task_id = Ecto.UUID.generate()

        refute has_element?(context.view, "[data-test='task'][data-task-id='#{new_task_id}']"),
               "expected the not-yet-started task to be absent initially"

        {:ok, Map.put(context, :new_task_id, new_task_id)}
      end

      when_ "the agent starts a new active task", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        project_id = context.scope.active_project_id

        Fixtures.session_fixture(context.scope, %{
          type: CodeMySpec.AgentTasks.ArchitectureDesign,
          status: :active,
          inserted_at: DateTime.add(now, -60, :second),
          updated_at: now,
          tasks: [
            %{
              id: context.new_task_id,
              status: :active,
              requirement_name: "architecture_designed",
              session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
              project_id: project_id,
              started_at: now
            }
          ]
        })

        {:ok, context}
      end

      then_ "the new task appears on the open view without a reload", context do
        assert has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.new_task_id}']"
               ),
               "expected the new task to push onto the open view in real time"

        {:ok, context}
      end
    end
  end
end
