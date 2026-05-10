defmodule CodeMySpecSpex.Story701.Criterion6062Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6062 — Rule: When a project has no stories,
  `/projects/:project_name` renders a per-project onboarding ladder
  with three rungs — init, project setup, first story — replacing
  the standard project home content.

  Surface contract:
    * [data-test="per-project-ladder"]
    * [data-test="init-rung"], [data-test="project-setup-rung"],
      [data-test="first-story-rung"]
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

  spex "Per-project ladder renders on /projects/:p when there are no stories" do
    scenario "Project with no stories shows the per-project ladder on its home page" do
      given_ "the user has a project with a local_path and zero stories", context do
        {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.name}")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the per-project ladder is rendered with three rungs", context do
        assert has_element?(context.view, "[data-test='per-project-ladder']"),
               "expected per-project-ladder on /projects/#{context.project.name} for a story-less project"

        for rung <- ~w(init-rung project-setup-rung first-story-rung) do
          assert has_element?(context.view, "[data-test='#{rung}']"),
                 "expected #{rung} to be present in the per-project ladder"
        end

        {:ok, context}
      end

      then_ "the standard project home dash-card grid is not rendered", context do
        # Anchor: prove a non-ladder element rendered so the refute below
        # isn't trivially satisfied by an empty page. Use a structural
        # element (the page heading) independent of the ladder itself.
        assert has_element?(context.view, "h1"),
               "expected the page to render an h1 anchor before refuting dash-card presence"

        refute has_element?(context.view, "[data-test='project-home-dashcards']"),
               "did not expect the standard project home dash-card grid while onboarding ladder is active"

        {:ok, context}
      end
    end
  end
end
