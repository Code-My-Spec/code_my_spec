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
        {:ok, _view, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/init/auth")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the step shows the Done badge", context do
        assert context.html =~ "badge-success",
               "expected the Auth per-step page to show a success badge, got:\n#{context.html}"

        assert context.html =~ "Done",
               "expected the Auth per-step page to render the literal Done badge, got:\n#{context.html}"

        {:ok, context}
      end
    end
  end
end
