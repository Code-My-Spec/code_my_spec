defmodule CodeMySpecSpex.Story602.Criterion5361Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5361 — Provider response without an email aborts registration.

  When the OAuth provider returns user data that contains no usable email
  address, the callback should abort the registration and redirect the user
  back to the login page with an error message. No user record or account
  should be created.

  Driven through the GitHub callback surface using a cassette that returns
  an empty email list from GET /user/emails and null email in GET /user.

  The desired behavior: redirect to /users/log-in with a flash error.
  The current behavior (before the fix): FunctionClauseError in
  get_user_by_email/1 when email is nil, resulting in a 500 response.
  The spec will fail until find_or_register_oauth_user handles nil email
  gracefully and the controller returns an {:error, reason} that routes
  to the login-page redirect.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.OAuthHelpers


  spex "Provider response without an email aborts registration" do
    scenario "GitHub callback with no email redirects to login with an error" do
      given_ "the GitHub provider response contains no email address", context do
        unique = System.unique_integer([:positive])

        # GitHub user with no email in either the profile or the emails endpoint.
        user_json = %{
          "id" => 90_000 + unique,
          "login" => "noemail-user-#{unique}",
          "node_id" => "U_no_email_#{unique}",
          "avatar_url" => "https://avatars.githubusercontent.com/u/#{90_000 + unique}?v=4",
          "type" => "User",
          "site_admin" => false,
          "name" => "No Email User",
          "email" => nil,
          "created_at" => "2020-01-01T00:00:00Z",
          "updated_at" => "2026-01-01T00:00:00Z"
        }

        # Empty emails list — provider returns no verified addresses.
        emails_json = []

        cassette_name = "github_5361_noemail_#{unique}"
        OAuthHelpers.build_github_cassette!(cassette_name, user_json, emails_json)

        {:ok, Map.put(context, :cassette_name, cassette_name)}
      end

      when_ "the GitHub OAuth callback fires", context do
        conn =
          OAuthHelpers.do_github_callback(
            build_conn(),
            context.cassette_name,
            "replay-state-5361"
          )

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the callback does not log the user in", context do
        # Regardless of whether the controller redirects or errors, the
        # important property is: no session token must be set. A session
        # token would mean a user was created and logged in despite having
        # no email address.
        refute Plug.Conn.get_session(context.conn, :user_token),
               "expected no user_token when the provider returns no email address"

        {:ok, context}
      end

      then_ "the response is a redirect to the login page (not a crash)", context do
        conn = context.conn

        # The desired behavior is a graceful redirect, not a 500 error.
        # The spec asserts on the redirect status code and destination.
        # If the server currently crashes (status 500), this assertion will
        # fail — indicating the fix is not yet applied.
        assert conn.status in [301, 302, 303, 307, 308],
               "expected a redirect response when email is missing, " <>
                 "got HTTP #{conn.status} — the controller should redirect to " <>
                 "/users/log-in instead of crashing"

        assert redirected_to(conn) == "/users/log-in",
               "expected redirect to /users/log-in when provider returns no email, " <>
                 "got: #{inspect(redirected_to(conn))}"

        {:ok, context}
      end
    end
  end

end
