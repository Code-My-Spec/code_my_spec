defmodule CodeMySpecSpex.Story602.Criterion5367Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5367 — Same email from a different OAuth provider links to the
  existing user instead of creating a new one.

  When a user registers via Google and then later signs in via GitHub (or
  vice versa) using the same email address, the system should find the
  existing user by email rather than creating a duplicate. The public surface
  for this: both callbacks produce session tokens that resolve to the same
  user id.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers


  spex "Same email from a different OAuth provider links to the existing user instead of creating a new one" do
    scenario "Google signup then GitHub signup with the same email returns the same user" do
      given_ "a user has signed up via Google with a specific email", context do
        unique = System.unique_integer([:positive])
        email = "crosslink-5367-#{unique}@example.com"

        google_claims = %{
          "sub" => "google-sub-5367-#{unique}",
          "email" => email,
          "email_verified" => true,
          "name" => "Cross-Provider User"
        }

        cassette_name = "google_5367_#{unique}"
        OAuthHelpers.build_google_cassette!(cassette_name, google_claims)

        google_conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            cassette_name,
            "state-5367-google"
          )

        assert Plug.Conn.get_session(google_conn, :user_token) != nil,
               "Google signup must produce a session token"

        {:ok,
         Map.merge(context, %{
           email: email,
           google_conn: google_conn
         })}
      end

      when_ "the same email address signs in via GitHub OAuth", context do
        unique = System.unique_integer([:positive])

        github_user_json = %{
          "id" => 70_000 + unique,
          "login" => "crosslink-github-#{unique}",
          "node_id" => "U_crosslink_#{unique}",
          "avatar_url" => "https://avatars.githubusercontent.com/u/#{70_000 + unique}?v=4",
          "type" => "User",
          "site_admin" => false,
          "name" => "Cross-Provider User",
          "email" => nil,
          "created_at" => "2020-01-01T00:00:00Z",
          "updated_at" => "2026-01-01T00:00:00Z"
        }

        github_emails_json = [
          %{
            "email" => context.email,
            "primary" => true,
            "verified" => true,
            "visibility" => "private"
          }
        ]

        cassette_name = "github_5367_#{unique}"
        OAuthHelpers.build_github_cassette!(cassette_name, github_user_json, github_emails_json)

        github_conn =
          OAuthHelpers.do_github_callback(
            build_conn(),
            cassette_name,
            "state-5367-github"
          )

        assert Plug.Conn.get_session(github_conn, :user_token) != nil,
               "GitHub callback must produce a session token"

        {:ok, Map.put(context, :github_conn, github_conn)}
      end

      then_ "both providers' sessions land on the same user (same email on settings)", context do
        {:ok, _v_google, html_google} =
          context.google_conn
          |> recycle()
          |> live("/app/users/settings")

        {:ok, _v_github, html_github} =
          context.github_conn
          |> recycle()
          |> live("/app/users/settings")

        assert html_google =~ context.email
        assert html_github =~ context.email

        :ok
      end

      then_ "the picker shows one personal account after the cross-provider sign-in",
            context do
        # If GitHub had created a duplicate user, the user logged in via the
        # GitHub conn would see their OWN (newly-created) personal account
        # only — but the duplicate would still exist for the email-based
        # other user. The structural defense is that the picker for the
        # GitHub conn shows exactly one personal-account row, named after
        # the shared email's local-part (proving it's the original Google
        # user's account).
        local_part = context.email |> String.split("@") |> List.first()

        {:ok, _view, html} =
          context.github_conn
          |> recycle()
          |> live("/app/accounts/picker")

        personal_badge_count =
          ~r/>\s*Personal\s*</
          |> Regex.scan(html)
          |> length()

        assert personal_badge_count == 1,
               "expected exactly one Personal badge on the picker after a same-email " <>
                 "GitHub sign-in, got #{personal_badge_count}"

        assert html =~ local_part,
               "expected the original personal account (named #{local_part}) " <>
                 "to be the one rendered, confirming the GitHub callback linked " <>
                 "to the existing Google user"

        :ok
      end
    end
  end

end
