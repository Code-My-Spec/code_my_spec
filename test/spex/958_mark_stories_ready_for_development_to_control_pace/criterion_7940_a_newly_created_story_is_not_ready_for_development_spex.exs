defmodule CodeMySpecSpex.Story958.Criterion7940Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7940 — A newly created story is not ready for development.

  New stories start parked; the user releases them explicitly. This is the
  default that makes the ready flag a gate rather than a reminder.

  Surface: StoryLive (LiveView).
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A newly created story is not ready for development" do
    scenario "The story is created parked" do
      given_ "the user is on the new story form", context do
        {:ok, form_live, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories/new")

        {:ok, Map.put(context, :form_live, form_live)}
      end

      when_ "the story is created", context do
        html =
          context.form_live
          |> form("[data-test='story-form']",
            story: %{
              title: "Players have a discrete age",
              story:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            }
          )
          |> render_submit()

        {:ok, Map.put(context, :submit_html, html)}
      end

      then_ "it is not ready for development", context do
        {:ok, _index_live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        # Anchor: the story really was created, so the readiness claim below
        # is about the flag and not about an empty page.
        assert html =~ "Players have a discrete age",
               "expected the new story to appear in the backlog, got: #{html}"

        assert html =~ "data-test=\"story-not-ready\"",
               "expected the new story to be marked not ready for development, got: #{html}"

        {:ok, context}
      end
    end
  end
end
