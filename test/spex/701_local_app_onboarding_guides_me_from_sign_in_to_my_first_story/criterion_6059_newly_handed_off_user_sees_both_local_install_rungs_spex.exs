defmodule CodeMySpecSpex.Story701.Criterion6059Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6059 — Rule: The local app shows a local-install ladder
  on `/` whose two rungs are *authed with the dashboard* and *has a
  linked project* — the ladder is rendered while either rung is
  incomplete and hidden once both are done.

  Newly handed-off user has no client_user row yet and no project
  with `local_path`. Both rungs render on `/`.

  Surface contract assumed by this spec:
    * [data-test="local-install-ladder"] root
    * [data-test="auth-rung"] with data-state="active|done"
    * [data-test="linked-project-rung"] with data-state="active|done|pending"
  """

  use CodeMySpecSpex.Case

  setup do
    # Newly handed-off, pre-OAuth-callback state: no client_users row
    # exists and no project carries a local_path. The bare conn drives
    # the LiveView; the local app should detect the unauth state and
    # render the local-install ladder.
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  spex "Local-install ladder renders both rungs for a brand-new user" do
    scenario "Newly handed-off user sees both local-install rungs" do
      given_ "the user has just landed on / with no auth and no linked project", context do
        {:ok, view, _html} = live(context.conn, "/")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the local-install ladder is rendered", context do
        assert has_element?(context.view, "[data-test='local-install-ladder']"),
               "expected the local-install ladder to render for a brand-new user"

        {:ok, context}
      end

      then_ "both rungs are visible in the ladder", context do
        assert has_element?(context.view, "[data-test='auth-rung']"),
               "expected auth-rung to be present in the local-install ladder"

        assert has_element?(context.view, "[data-test='linked-project-rung']"),
               "expected linked-project-rung to be present in the local-install ladder"

        {:ok, context}
      end
    end
  end
end
