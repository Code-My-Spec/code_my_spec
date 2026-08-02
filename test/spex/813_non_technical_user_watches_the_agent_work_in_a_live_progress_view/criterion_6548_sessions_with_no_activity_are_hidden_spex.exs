defmodule CodeMySpecSpex.Story813.Criterion6548Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6548 — Rule (exclusion arm): the timeline excludes sessions with
  no activity — those whose start time equals their last-updated time.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. We seed one no-activity session
  (`inserted_at == updated_at`) alongside one active session (anchor), open
  the timeline, and assert the no-activity session is absent while the
  active one renders.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sessions with no activity are hidden" do
    scenario "a session whose start equals its last update is not shown" do
      given_ "a no-activity session and an active session both exist", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        idle =
          Fixtures.session_fixture(context.scope, %{
            type: CodeMySpec.AgentTasks.ArchitectureDesign,
            status: :active,
            inserted_at: now,
            updated_at: now,
            tasks: []
          })

        active =
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

        {:ok, Map.merge(context, %{idle: idle, active: active})}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the no-activity session is absent while the active one renders", context do
        assert has_element?(
                 context.view,
                 "[data-test='session'][data-session-id='#{context.active.id}']"
               ),
               "expected the active session to render (anchor)"

        refute has_element?(
                 context.view,
                 "[data-test='session'][data-session-id='#{context.idle.id}']"
               ),
               "expected the no-activity session (start == updated) to be hidden"

        {:ok, context}
      end
    end
  end
end
