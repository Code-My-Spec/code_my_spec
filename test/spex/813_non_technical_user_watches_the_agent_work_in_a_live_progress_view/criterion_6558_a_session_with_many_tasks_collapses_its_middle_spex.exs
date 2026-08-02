defmodule CodeMySpecSpex.Story813.Criterion6558Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6558 — Rule: a session with many tasks collapses its middle to the
  newest few + oldest few, with an expandable "… N more steps" control.

  Surface: `CodeMySpecLocalWeb.AgentProgressLive`. We seed a session with
  more than ten tasks, assert a middle task is hidden behind
  `[data-test="show-more-tasks"]` while the newest/oldest remain visible,
  then click the control and assert the hidden task appears.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A session with many tasks collapses its middle" do
    scenario "the middle is hidden behind a show-more control until expanded" do
      given_ "a session with more than ten tasks", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        # index 0 = oldest, 11 = newest
        tasks =
          for i <- 0..11 do
            %{
              id: Ecto.UUID.generate(),
              status: :completed,
              requirement_name: "step_#{i}",
              session_type: CodeMySpec.AgentTasks.ComponentCode,
              project_id: project_id,
              started_at: DateTime.add(earlier, i * 60, :second),
              completed_at: DateTime.add(earlier, i * 60 + 30, :second)
            }
          end

        Fixtures.session_fixture(context.scope, %{
          type: CodeMySpec.AgentTasks.ComponentCode,
          status: :active,
          inserted_at: earlier,
          updated_at: now,
          tasks: tasks
        })

        # A middle task (index 5) — not in the newest-2 / oldest-2 windows.
        {:ok, Map.put(context, :middle_id, Enum.at(tasks, 5).id)}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the middle task is hidden behind a show-more control", context do
        assert has_element?(context.view, "[data-test='show-more-tasks']"),
               "expected a show-more control on a session with many tasks"

        refute has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.middle_id}']"
               ),
               "expected the collapsed middle task to be hidden"

        {:ok, context}
      end

      then_ "clicking show-more reveals the hidden tasks", context do
        context.view |> element("[data-test='show-more-tasks']") |> render_click()

        assert has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.middle_id}']"
               ),
               "expected the hidden middle task to appear after expanding"

        {:ok, context}
      end
    end
  end
end
