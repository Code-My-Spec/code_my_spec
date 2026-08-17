defmodule CodeMySpecSpex.Story711.Criterion6252Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6252 — OAuth-authenticated scope satisfies Init.Auth.

  When a `ClientUser` row exists with an unexpired OAuth token (the same
  predicate `OAuthClient.authenticated?/0` checks) and the engineer opens
  the Auth init step's per-step page, the page renders the step with the
  success ("Done") badge.

  Surface: `InitLive` at `/projects/:project_name/init/auth`. The
  authenticated state is set up via `Fixtures.client_user_fixture/1`,
  which seeds the same row shape the real OAuth flow writes.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.Auth gates init on OAuthClient.authenticated?; failure emits manual sign-in guidance" do
    scenario "OAuth-authenticated scope renders the Auth step as Done on the per-step page" do
      given_ "the local OAuth client reports authenticated? = true",
             context do
        _client_user = Fixtures.client_user_fixture(context.user)
        {:ok, context}
      end

      when_ "the engineer opens the Auth per-step page", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/init/auth")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the step shows the Done badge", context do
        # The badge, not the page. `html =~ "badge-success"` is also true of the
        # checklist in the sidebar, which carries a green tick for every step
        # already done — so both assertions passed on a page where *this* step
        # was not done. The sidebar ticks render "✓", so asking for the
        # success badge that reads "Done" names this step's badge alone.
        assert has_element?(context.view, "span.badge-success", "Done"),
               "expected the Auth step's own badge to read Done, got:\n#{context.html}"

        {:ok, context}
      end
    end
  end
end
