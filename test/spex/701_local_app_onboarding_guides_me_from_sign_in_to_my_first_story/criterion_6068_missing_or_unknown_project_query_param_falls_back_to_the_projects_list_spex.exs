defmodule CodeMySpecSpex.Story701.Criterion6068Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6068 — Rule: Failure path on the handoff URL — if the
  query param is missing or names a project the local DB doesn't
  know, the local app falls back to the standard projects list
  rather than erroring.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_and_log_in_user

  setup context do
    _client_user = Fixtures.client_user_fixture(context.user)
    :ok
  end

  spex "Unknown project query param falls back to the projects list" do
    scenario "Missing or unknown project query param falls back to the projects list" do
      given_ "the user lands on / with a project id the local DB doesn't know", context do
        {:ok, view, _html} = live(context.conn, "/?project=999999999")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the projects list page renders", context do
        rendered = render(context.view)

        assert rendered =~ "Projects",
               "expected the projects list page to render as fallback when the project id is unknown"

        {:ok, context}
      end

      then_ "no error flash is shown for the missing project", context do
        rendered = render(context.view)

        # Anchor inside this then_ so the refute isn't trivially passing
        # against an empty render: prove the projects list shell is here.
        assert rendered =~ "Projects",
               "expected the projects list page to render its heading before refuting an error flash"

        refute rendered =~ "Project not found",
               "did not expect an error flash on the projects list fallback"

        {:ok, context}
      end
    end
  end
end
