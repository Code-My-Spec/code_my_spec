defmodule CodeMySpecSpex.Story602.Criterion5362Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5362 — First-time GitHub signup creates a personal account in the same callback.

  When a brand-new user signs up via GitHub OAuth, the callback should call
  Accounts.ensure_personal_account/1 before logging the user in. The result
  is that the user already has a personal account by the time they land on
  the onboarding screen.

  Observable through the public surface: after the callback, navigating to
  /app/accounts shows the personal account, or the authenticated onboarding
  page renders without the "no accounts" picker prompt.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers


  spex "First-time GitHub signup creates a personal account in the same callback" do
    scenario "new GitHub user has a personal account by the time the callback completes" do
      given_ "the GitHub provider response is for a brand-new email address", context do
        unique = System.unique_integer([:positive])

        user_json = %{
          "id" => 80_000 + unique,
          "login" => "github-new-#{unique}",
          "node_id" => "U_github_#{unique}",
          "avatar_url" => "https://avatars.githubusercontent.com/u/#{80_000 + unique}?v=4",
          "type" => "User",
          "site_admin" => false,
          "name" => "GitHub New User #{unique}",
          "email" => nil,
          "created_at" => "2020-01-01T00:00:00Z",
          "updated_at" => "2026-01-01T00:00:00Z"
        }

        email = "github-new-#{unique}@example.com"

        emails_json = [
          %{
            "email" => email,
            "primary" => true,
            "verified" => true,
            "visibility" => "private"
          }
        ]

        cassette_name = "github_5362_#{unique}"
        OAuthHelpers.build_github_cassette!(cassette_name, user_json, emails_json)

        {:ok,
         Map.merge(context, %{
           email: email,
           cassette_name: cassette_name
         })}
      end

      when_ "the GitHub OAuth callback completes", context do
        conn =
          OAuthHelpers.do_github_callback(
            build_conn(),
            context.cassette_name,
            "replay-state-5362"
          )

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the user is redirected to onboarding", context do
        assert redirected_to(context.conn) in ["/app/onboarding", "/app", "/"],
               "expected redirect to onboarding for new GitHub user, " <>
                 "got: #{inspect(redirected_to(context.conn))}"

        {:ok, context}
      end

      then_ "the account picker lists a personal account named after the user's email",
            context do
        user_token = Plug.Conn.get_session(context.conn, :user_token)
        assert user_token != nil, "expected user_token in session after GitHub signup"

        # Personal account names are derived from the email local-part (see
        # AccountsRepository.extract_name_from_email/1). The picker renders
        # every account this user owns with a "Personal"/"Team" badge — so
        # finding the local-part next to the Personal label proves the
        # personal account was created during the OAuth callback.
        local_part = context.email |> String.split("@") |> List.first()

        {:ok, _view, html} =
          context.conn
          |> recycle()
          |> live("/app/accounts/picker")

        assert html =~ "Personal",
               "expected /app/accounts/picker to render a Personal badge after GitHub OAuth signup"

        assert html =~ local_part,
               "expected the personal account named after the email local-part " <>
                 "(#{local_part}) to appear on the picker"

        {:ok, context}
      end
    end
  end

end
