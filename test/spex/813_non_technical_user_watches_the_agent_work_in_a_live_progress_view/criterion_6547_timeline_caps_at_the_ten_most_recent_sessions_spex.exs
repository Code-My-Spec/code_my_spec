defmodule CodeMySpecSpex.Story813.Criterion6547Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6547 — Rule: the timeline shows only the most recent active
  sessions, capped at the latest ten.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`. We seed eleven active sessions with
  staggered `updated_at` timestamps, open the timeline, and assert the ten
  most recent render while the single oldest is excluded.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Timeline caps at the ten most recent sessions" do
    scenario "only the ten most recently updated sessions render" do
      given_ "eleven active sessions exist with staggered activity", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        project_id = context.scope.active_project_id

        # index 0 = oldest, index 10 = newest
        sessions =
          for i <- 0..10 do
            inserted = DateTime.add(now, -(11 - i) * 120, :second)
            updated = DateTime.add(inserted, 60, :second)

            Fixtures.session_fixture(context.scope, %{
              type: CodeMySpec.AgentTasks.ArchitectureDesign,
              status: :active,
              inserted_at: inserted,
              updated_at: updated,
              tasks: [
                %{
                  id: Ecto.UUID.generate(),
                  status: :active,
                  requirement_name: "architecture_designed",
                  session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
                  project_id: project_id,
                  started_at: inserted
                }
              ]
            })
          end

        {:ok, Map.merge(context, %{oldest: List.first(sessions), newest: List.last(sessions)})}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the newest session renders and the eleventh-oldest is excluded", context do
        assert has_element?(
                 context.view,
                 "[data-test='session'][data-session-id='#{context.newest.id}']"
               ),
               "expected the most recent session to render"

        refute has_element?(
                 context.view,
                 "[data-test='session'][data-session-id='#{context.oldest.id}']"
               ),
               "expected the eleventh-oldest session to be dropped by the ten-session cap"

        {:ok, context}
      end
    end
  end
end
