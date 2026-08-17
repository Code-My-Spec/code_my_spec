defmodule CodeMySpecSpex.Story813.Criterion6559Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6559 — Rule: each task is labelled by its own type while the
  session itself is an untyped container.

  Surface: `CodeMySpecLocalWeb.AgentProgressLive`. We seed one session with
  tasks of two different types (architecture, qa) and assert each task row
  carries its own `[data-test="task-type"]` tag with the type derived from
  that task — not the session.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each task is labelled by its own type" do
    scenario "tasks carry their own type tags; the session has none" do
      given_ "a session whose tasks are of different types", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        arch_id = Ecto.UUID.generate()
        qa_id = Ecto.UUID.generate()

        Fixtures.session_fixture(context.scope, %{
          type: CodeMySpec.AgentTasks.ArchitectureDesign,
          status: :active,
          inserted_at: earlier,
          updated_at: now,
          tasks: [
            %{
              id: arch_id,
              status: :completed,
              requirement_name: "architecture_designed",
              session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
              project_id: project_id,
              started_at: earlier,
              completed_at: DateTime.add(earlier, 60, :second)
            },
            %{
              id: qa_id,
              status: :active,
              requirement_name: "qa_complete",
              session_type: CodeMySpec.AgentTasks.QaStory,
              project_id: project_id,
              started_at: DateTime.add(earlier, 120, :second)
            }
          ]
        })

        {:ok, Map.merge(context, %{arch_id: arch_id, qa_id: qa_id})}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "each task shows a type tag derived from its own type", context do
        # Each tag is read where it hangs, because the criterion is that a task
        # is labelled by *its own* type. Against the whole page these were
        # `html =~ "arch"` and `html =~ "qa"`, which a search box satisfies by
        # itself — "search" contains "arch" — and which would both still pass
        # if the two tags rendered the same type.
        assert has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.arch_id}'] [data-test='task-type']",
                 "arch"
               ),
               "expected the architecture task tag to read its own type"

        assert has_element?(
                 context.view,
                 "[data-test='task'][data-task-id='#{context.qa_id}'] [data-test='task-type']",
                 "qa"
               ),
               "expected the qa task tag to read its own type"

        {:ok, context}
      end

      then_ "the session header itself carries no type label", context do
        # The session header is the literal "Session", not a typed name.
        assert has_element?(
                 context.view,
                 "[data-test='session'] .cms-session-title"
               ),
               "expected a neutral session header"

        refute has_element?(context.view, "[data-test='session'] > [data-test='task-type']"),
               "expected no type tag directly on the session (only on its tasks)"

        {:ok, context}
      end
    end
  end
end
