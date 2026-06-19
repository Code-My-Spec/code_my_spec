defmodule CodeMySpecSpex.Story813.Criterion6551Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6551 — Rule (idle arm): the timeline expands nothing when no task
  is active.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. We seed a session whose only task is
  completed (no active task anywhere), open the timeline, and assert no task
  is expanded while the timeline itself still renders (anchor).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Nothing is expanded when the agent is idle" do
    scenario "no task is expanded when there is no active task" do
      given_ "a session whose only task is already completed", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        Fixtures.session_fixture(context.scope, %{
          type: CodeMySpec.AgentTasks.ArchitectureDesign,
          status: :complete,
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
            }
          ]
        })

        {:ok, context}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the timeline renders but no task is expanded", context do
        assert has_element?(context.view, "[data-test='timeline']"),
               "expected the timeline to render even when idle (anchor)"

        refute has_element?(context.view, "[data-test='task'][data-expanded='true']"),
               "expected no task to be expanded while the agent is idle"

        {:ok, context}
      end
    end
  end
end
