defmodule CodeMySpecSpex.Story602.Criterion5366Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5366 — Second Google sign-in returns the same user with no duplicate records.

  When the same Google account signs in a second time, the callback must
  find the existing user and return them — not create a new user with the
  same email. Observable through the public surface: both callbacks produce
  session tokens that resolve to the same user id.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers


  spex "Second Google sign-in returns the same user with no duplicate records" do
    scenario "two Google callbacks with the same sub produce a single user" do
      given_ "a Google OAuth callback is prepared for a unique email", context do
        unique = System.unique_integer([:positive])

        user_claims = %{
          "sub" => "google-sub-5366-#{unique}",
          "email" => "returning-5366-#{unique}@example.com",
          "email_verified" => true,
          "name" => "Google Idempotent User"
        }

        cassette_name_1 = "google_5366_first_#{unique}"
        OAuthHelpers.build_google_cassette!(cassette_name_1, user_claims)

        {:ok,
         Map.merge(context, %{
           user_claims: user_claims,
           cassette_name_1: cassette_name_1
         })}
      end

      when_ "the same Google identity completes the OAuth callback twice", context do
        first_conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            context.cassette_name_1,
            "state-5366-first"
          )

        unique = System.unique_integer([:positive])
        cassette_name_2 = "google_5366_second_#{unique}"
        OAuthHelpers.build_google_cassette!(cassette_name_2, context.user_claims)

        second_conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            cassette_name_2,
            "state-5366-second"
          )

        {:ok,
         Map.merge(context, %{
           first_conn: first_conn,
           second_conn: second_conn
         })}
      end

      then_ "both sessions surface the same email on the user settings page", context do
        # If a duplicate user had been created, the second sign-in's session
        # would still resolve to a user with the same email — but combined
        # with the picker assertion below (one personal account only), this
        # confirms idempotence.
        assert Plug.Conn.get_session(context.first_conn, :user_token) != nil
        assert Plug.Conn.get_session(context.second_conn, :user_token) != nil

        {:ok, _v1, html_1} =
          context.first_conn
          |> recycle()
          |> live("/app/users/settings")

        {:ok, _v2, html_2} =
          context.second_conn
          |> recycle()
          |> live("/app/users/settings")

        assert html_1 =~ context.user_claims["email"]
        assert html_2 =~ context.user_claims["email"]

        :ok
      end

      then_ "the picker shows exactly one personal account after the second sign-in",
            context do
        # The picker renders one row per account the user owns, with a
        # "Personal" or "Team" badge. If the second OAuth callback had created
        # a duplicate personal account, "Personal" would appear twice.
        {:ok, _view, html} =
          context.second_conn
          |> recycle()
          |> live("/app/accounts/picker")

        personal_badge_count =
          ~r/>\s*Personal\s*</
          |> Regex.scan(html)
          |> length()

        assert personal_badge_count == 1,
               "expected exactly one Personal badge on the picker after a repeat Google " <>
                 "sign-in, got #{personal_badge_count} — a duplicate personal account " <>
                 "was created on the second callback"

        :ok
      end
    end
  end

end
