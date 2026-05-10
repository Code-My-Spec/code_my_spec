defmodule CodeMySpecSpex.Story701.Criterion6061Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6061 — Rule: The local-install ladder is hidden once
  both rungs are done.

  Once the user is authed locally and at least one project has a
  `local_path`, `/` renders the projects list as the primary content
  with no local-install ladder above it.
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

  spex "Fully set-up user lands on the projects list, not the local-install ladder" do
    scenario "Fully set-up user does not see the local-install ladder" do
      given_ "the user is authed locally and has a project with a local_path", context do
        {:ok, view, _html} = live(context.conn, "/")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the local-install ladder is not rendered", context do
        # Anchor: prove SOMETHING rendered (the projects list) before
        # refuting the ladder's absence.
        assert has_element?(context.view, "h1"),
               "expected the projects list page to render an h1 anchor"

        refute has_element?(context.view, "[data-test='local-install-ladder']"),
               "did not expect the local-install ladder once both rungs are done"

        {:ok, context}
      end

      then_ "the projects list is the primary content", context do
        rendered = render(context.view)

        assert rendered =~ "Projects",
               "expected the page heading to identify it as the projects list"

        {:ok, context}
      end
    end
  end
end
