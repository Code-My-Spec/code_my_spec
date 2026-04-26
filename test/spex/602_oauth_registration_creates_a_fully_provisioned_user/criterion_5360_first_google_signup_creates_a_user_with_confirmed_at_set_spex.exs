defmodule CodeMySpecSpex.Story602.Criterion5360Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5360 — First Google signup creates a user with confirmed_at set.

  A new user who signs up via Google OAuth should be immediately confirmed
  (no email verification step required). Observable through the public surface:
  after the callback the user is redirected to /app/onboarding or /app, not
  to a confirmation prompt. The confirmed state is further observable because
  a subsequent authenticated request to /app succeeds without any
  "please confirm your email" interstitial.
  """

  use CodeMySpecSpex.Case

  # OAuth routes live on the main web endpoint, not the local web endpoint.
  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers


  spex "First Google signup creates a user with confirmed_at set" do
    scenario "new Google user is redirected to onboarding without a confirmation step" do
      given_ "a Google OAuth callback is prepared for a brand-new email address", context do
        unique = System.unique_integer([:positive])

        user_claims = %{
          "sub" => "google-sub-5360-#{unique}",
          "email" => "new-google-5360-#{unique}@example.com",
          "email_verified" => true,
          "name" => "Google Test 5360",
          "given_name" => "Google",
          "family_name" => "Test"
        }

        cassette_name = "google_5360_#{unique}"
        OAuthHelpers.build_google_cassette!(cassette_name, user_claims)

        {:ok, Map.merge(context, %{user_claims: user_claims, cassette_name: cassette_name})}
      end

      when_ "the Google OAuth callback completes", context do
        conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            context.cassette_name,
            "google-state-5360"
          )

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the user is redirected to onboarding without being asked to confirm their email",
            context do
        assert redirected_to(context.conn) in ["/app/onboarding", "/app", "/"],
               "expected redirect to onboarding or app after Google signup, " <>
                 "got: #{inspect(redirected_to(context.conn))}"

        refute redirected_to(context.conn) =~ "confirm",
               "expected no confirmation-step redirect for an OAuth-registered user"

        :ok
      end

      then_ "the logged-in session resolves to the new Google identity on the settings page",
            context do
        user_token = Plug.Conn.get_session(context.conn, :user_token)

        assert user_token != nil,
               "expected a user_token in session after successful OAuth callback"

        {:ok, _view, html} =
          context.conn
          |> recycle()
          |> live("/app/users/settings")

        assert html =~ context.user_claims["email"],
               "expected /app/users/settings to render the OAuth user's email " <>
                 "(#{context.user_claims["email"]}), confirming the session resolves to that user"

        :ok
      end
    end
  end

end
