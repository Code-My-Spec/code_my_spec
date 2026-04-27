defmodule CodeMySpecSpex.Story602.Criterion5369Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5369 — Integration save failure still leaves the user logged in
  with user and personal account.

  The controller calls Integrations.save_integration/4 but does not check its
  return value — it fires and forgets. If save_integration fails (e.g., because
  the token response omits the required access_token field and the changeset
  validation rejects it), the user should still be logged in with a session
  token, and their personal account should still exist.

  We induce the failure through the surface layer by replaying a Google OIDC
  cassette whose token response carries an empty `access_token`. Ecto's
  `cast` normalizes "" to nil for the required field, so the Integration
  changeset fails validation and the upsert returns `{:error, changeset}`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers


  spex "Integration save failure still leaves the user logged in with user and personal account" do
    scenario "Google callback with missing access_token: user is logged in, account exists, integration is absent" do
      given_ "the Google token response carries an empty access_token (simulating a save-failure path)",
             context do
        unique = System.unique_integer([:positive])

        user_claims = %{
          "sub" => "google-sub-5369-#{unique}",
          "email" => "google-5369-#{unique}@example.com",
          "email_verified" => true,
          "name" => "Save Failure Test User"
        }

        cassette_name = "google_5369_no_token_#{unique}"

        # Token response with empty-string access_token — Assent accepts it as
        # present, but Ecto's `cast` normalizes "" to nil for the required
        # field, so the Integration changeset fails validation and the upsert
        # returns {:error, changeset}. The controller fires-and-forgets the
        # result, so the user is still logged in despite the save failure.
        OAuthHelpers.build_google_cassette!(cassette_name, user_claims,
          token_response_overrides: %{"access_token" => ""}
        )

        {:ok,
         Map.merge(context, %{
           user_claims: user_claims,
           cassette_name: cassette_name
         })}
      end

      when_ "the Google OAuth callback fires", context do
        conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            context.cassette_name,
            "state-5369"
          )

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the user is still logged in despite the integration save failure", context do
        user_token = Plug.Conn.get_session(context.conn, :user_token)

        assert user_token != nil,
               "expected a session token even when integration save fails — " <>
                 "the controller must not gate login on save_integration success"

        {:ok, _view, html} =
          context.conn
          |> recycle()
          |> live("/app/users/settings")

        assert html =~ context.user_claims["email"],
               "expected /app/users/settings to render the OAuth user's email " <>
                 "even though the integration save failed"

        :ok
      end

      then_ "the user has a personal account despite the integration save failure", context do
        # The picker lists every account the user owns. A "Personal" badge
        # confirms ensure_personal_account/1 ran before the failed
        # save_integration call.
        local_part = context.user_claims["email"] |> String.split("@") |> List.first()

        {:ok, _view, html} =
          context.conn
          |> recycle()
          |> live("/app/accounts/picker")

        assert html =~ "Personal",
               "expected a Personal badge on the picker — ensure_personal_account " <>
                 "must run before save_integration so a save failure can't strand the user"

        assert html =~ local_part,
               "expected the personal account named after the email local-part " <>
                 "(#{local_part}) to be listed on the picker"

        :ok
      end
    end
  end
end
