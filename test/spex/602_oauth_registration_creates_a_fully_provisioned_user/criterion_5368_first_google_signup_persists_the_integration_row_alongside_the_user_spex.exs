defmodule CodeMySpecSpex.Story602.Criterion5368Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5368 — First Google signup persists the integration row alongside the user.

  When a brand-new user signs up via Google OAuth, the callback should call
  Integrations.save_integration/4, persisting the provider connection so the
  user's settings page shows "Connected" for Google.

  Observable through the public surface: after the OAuth callback, navigating
  to /app/users/settings shows "Connected" in the Google section rather than
  "Not connected".
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers


  spex "First Google signup persists the integration row alongside the user" do
    scenario "settings page shows Google as connected after first OAuth signup" do
      given_ "a Google OAuth callback is prepared for a brand-new email", context do
        unique = System.unique_integer([:positive])

        user_claims = %{
          "sub" => "google-sub-5368-#{unique}",
          "email" => "google-int-5368-#{unique}@example.com",
          "email_verified" => true,
          "name" => "Google Integration Test"
        }

        cassette_name = "google_5368_#{unique}"
        OAuthHelpers.build_google_cassette!(cassette_name, user_claims)

        {:ok, Map.put(context, :cassette_name, cassette_name)}
      end

      when_ "the Google OAuth callback completes", context do
        callback_conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            context.cassette_name,
            "state-5368"
          )

        user_token = Plug.Conn.get_session(callback_conn, :user_token)
        assert user_token != nil, "expected user_token after Google signup"

        {:ok, Map.put(context, :user_token, user_token)}
      end

      then_ "the user's settings page shows Google as connected", context do
        # The settings page at /app/users/settings renders @google_connected
        # from Integrations.connected?(scope, :google). If save_integration/4
        # was called during the callback, this must render "Connected".
        # The settings page uses :require_sudo_mode which requires authentication
        # within the last 20 minutes — a freshly created OAuth session qualifies.
        authed_conn =
          build_conn()
          |> Phoenix.ConnTest.init_test_session(%{})
          |> Plug.Conn.put_session(:user_token, context.user_token)

        result = Phoenix.LiveViewTest.live(authed_conn, "/app/users/settings")

        case result do
          {:ok, _view, html} ->
            # The settings template renders "Connected" (in green) when
            # @google_connected is true, and "Not connected" when it is false.
            assert html =~ "Connected",
                   "expected the settings page to show Google as Connected after signup, " <>
                     "but 'Connected' was not found in the rendered HTML"

            refute html =~ "Not connected",
                   "expected 'Not connected' to be absent when Google integration is saved"

            :ok

          {:error, {:live_redirect, %{to: to}}} ->
            flunk(
              "settings page redirected to #{inspect(to)} — " <>
                "did the OAuth session token satisfy sudo_mode? check?"
            )

          {:error, {:redirect, %{to: to}}} ->
            flunk("unexpected redirect to #{inspect(to)} when loading settings")

          other ->
            flunk("unexpected live/2 result: #{inspect(other)}")
        end
      end
    end
  end

end
