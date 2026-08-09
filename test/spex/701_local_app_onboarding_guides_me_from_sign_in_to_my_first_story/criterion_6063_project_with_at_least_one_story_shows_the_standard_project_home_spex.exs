defmodule CodeMySpecSpex.Story701.Criterion6063Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6063 — Rule: Once the project has at least one story,
  `/projects/:project_name` renders the standard project home (dash
  card grid) and the per-project ladder is not shown.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_and_log_in_user

  setup context do
    _client_user = Fixtures.client_user_fixture(context.user)
    :ok
  end

  setup :setup_active_account
  setup :setup_active_project

  setup context do
    # Drive the CreateStory MCP tool surface to land at least one
    # story for this project. Any story counts; the ladder's
    # done-check is length(Stories.list_stories(scope)) > 0. No
    # component link — the ladder doesn't care.
    _story =
      CodeMySpecSpex.StoryHelpers.create_story(context.scope,
        title: "First story",
        description: "Any story counts as 'done' for the per-project ladder.",
        acceptance_criteria: ["The story exists."]
      )

    :ok
  end

  spex "Project with stories shows the standard home, not the ladder" do
    scenario "Project with at least one story shows the standard project home" do
      given_ "the user has a project with at least one story", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the per-project ladder is not rendered", context do
        # Anchor: a non-ladder element rendered.
        assert has_element?(context.view, "[data-test='project-home-dashcards']"),
               "expected the standard project home dash-card grid to render once stories exist"

        refute has_element?(context.view, "[data-test='per-project-ladder']"),
               "did not expect the per-project ladder once the project has stories"

        {:ok, context}
      end
    end
  end
end
