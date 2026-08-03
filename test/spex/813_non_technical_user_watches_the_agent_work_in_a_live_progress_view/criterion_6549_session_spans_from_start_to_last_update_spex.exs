defmodule CodeMySpecSpex.Story813.Criterion6549Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6549 — Rule: each session's timeline extent runs from when it
  started to when it was last updated.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. The session renders an extent element
  carrying both endpoints. We seed a session with distinct
  `inserted_at`/`updated_at` and assert the extent element renders both a
  start and a last-updated endpoint.

  Contract: `[data-test="session-extent"]` carries `data-started-at` and
  `data-updated-at` attributes reflecting the session's two endpoints.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Session spans from start to last update" do
    scenario "the session extent renders both its start and last-update endpoints" do
      given_ "a session started well before it was last updated", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        started = DateTime.add(now, -2700, :second)
        project_id = context.scope.active_project_id

        session =
          Fixtures.session_fixture(context.scope, %{
            type: CodeMySpec.AgentTasks.ArchitectureDesign,
            status: :active,
            inserted_at: started,
            updated_at: now,
            tasks: [
              %{
                id: Ecto.UUID.generate(),
                status: :active,
                requirement_name: "architecture_designed",
                session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
                project_id: project_id,
                started_at: started
              }
            ]
          })

        {:ok, Map.put(context, :session, session)}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the session extent carries both a start and a last-updated endpoint",
            context do
        scope = "[data-test='session'][data-session-id='#{context.session.id}']"

        assert has_element?(
                 context.view,
                 "#{scope} [data-test='session-extent'][data-started-at]"
               ),
               "expected the session extent to render its start endpoint"

        assert has_element?(
                 context.view,
                 "#{scope} [data-test='session-extent'][data-updated-at]"
               ),
               "expected the session extent to render its last-updated endpoint"

        {:ok, context}
      end
    end
  end
end
