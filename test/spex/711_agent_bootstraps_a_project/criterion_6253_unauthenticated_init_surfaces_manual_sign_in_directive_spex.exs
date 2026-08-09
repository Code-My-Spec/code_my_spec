defmodule CodeMySpecSpex.Story711.Criterion6253Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6253 — Unauthenticated init surfaces manual sign-in directive.

  When no `ClientUser` row exists with an OAuth token and the engineer
  opens the Auth init step's per-step page, the page:
    1. Renders the step with a "Not done" badge.
    2. Surfaces a per-step prompt that tells the user to sign in to
       CodeMySpec manually.
    3. States the agent cannot complete this step automatically.

  Surface: `InitLive` at `/projects/:project_name/init/auth`. Default
  test state has no client_user row, so `OAuthClient.authenticated?/0`
  returns false.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.Auth gates init on OAuthClient.authenticated?; failure emits manual sign-in guidance" do
    scenario "Unauthenticated init surfaces manual sign-in directive on the per-step page" do
      given_ "the local OAuth client reports authenticated? = false (no client_user seeded)",
             context do
        {:ok, context}
      end

      when_ "the engineer opens the Auth per-step page", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/init/auth")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the step shows the Not done badge", context do
        assert context.html =~ "badge-warning",
               "expected the not-done badge on the Auth per-step page, got:\n#{context.html}"

        {:ok, context}
      end

      and_ "the per-step prompt tells the user to sign in to CodeMySpec manually",
           context do
        prompt_text =
          context.view
          |> element(~s|pre|)
          |> render()

        assert prompt_text =~ ~r/sign in/i,
               "expected prompt to mention sign in, got:\n#{prompt_text}"

        assert prompt_text =~ ~r/CodeMySpec/,
               "expected prompt to mention CodeMySpec, got:\n#{prompt_text}"

        {:ok, Map.put(context, :prompt_text, prompt_text)}
      end

      and_ "the per-step prompt states the agent cannot complete this step automatically",
           context do
        assert context.prompt_text =~ ~r/cannot complete it automatically|requires user interaction/i,
               "expected prompt to say the agent can't do this automatically, got:\n#{context.prompt_text}"

        {:ok, context}
      end
    end
  end
end
