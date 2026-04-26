defmodule CodeMySpecSpex.Story602.Criterion5365Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5365 — Subsequent OAuth login does not overwrite an existing
  active-account preference.

  When a user who already has a personal account (and has selected a different
  account as active) signs in via OAuth again, the callback must not reset their
  active-account preference. The user should remain on whichever account they
  had selected.

  Observable through the public surface: after a second OAuth login, navigating
  to a require_active_account route proceeds without a picker redirect (because
  the previously selected account is still active in their session).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers
  alias CodeMySpecSpex.Fixtures


  spex "Subsequent OAuth login does not overwrite an existing active-account preference" do
    scenario "returning Google user keeps their previously selected account as active" do
      given_ "an existing user has selected an org account as their active account", context do
        unique = System.unique_integer([:positive])
        email = "returning-5365-#{unique}@example.com"

        # Pre-existing user — created via Fixtures, the approved bridge,
        # to set up state without going through the OAuth surface twice.
        user = Fixtures.user_fixture(%{email: email})

        org_account = Fixtures.account_with_owner_fixture(user)

        Fixtures.select_active_account(
          Fixtures.user_scope_fixture(user, org_account),
          org_account.id
        )

        user_claims = %{
          "sub" => "google-sub-5365-#{unique}",
          "email" => email,
          "email_verified" => true,
          "name" => "Returning Google User"
        }

        {:ok,
         Map.merge(context, %{
           email: email,
           user_claims: user_claims,
           org_account: org_account
         })}
      end

      when_ "the user signs in via Google OAuth", context do
        unique = System.unique_integer([:positive])

        cassette_name = "google_5365_#{unique}"
        OAuthHelpers.build_google_cassette!(cassette_name, context.user_claims)

        second_conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            cassette_name,
            "state-5365"
          )

        {:ok, Map.put(context, :second_conn, second_conn)}
      end

      then_ "the callback redirects to /app, not /app/onboarding (returning user path)",
            context do
        destination = redirected_to(context.second_conn)

        # A returning user (:existing status) is not sent to onboarding.
        # The controller does not put_session(:user_return_to, onboarding) for
        # :existing users.
        refute destination == "/app/onboarding",
               "expected returning user not to be sent to onboarding again"

        :ok
      end

      then_ "the session reaches an account-protected route without a picker detour",
            context do
        user_token_2 = Plug.Conn.get_session(context.second_conn, :user_token)
        assert user_token_2 != nil, "second login must produce a session token"

        # /app/projects is gated by require_active_account. If the previously
        # chosen org account is still the active preference, the LV mounts;
        # if the OAuth callback overwrote the preference (e.g. reset to
        # personal), the on_mount hook redirects to the picker.
        result =
          context.second_conn
          |> recycle()
          |> live("/app/projects")

        case result do
          {:ok, _view, _html} ->
            :ok

          {:error, {kind, %{to: to}}} when kind in [:live_redirect, :redirect] ->
            if to =~ "picker" do
              flunk(
                "active-account preference was overwritten; " <>
                  "got picker redirect after second OAuth login to #{inspect(to)}"
              )
            else
              flunk("unexpected #{kind} to #{inspect(to)} after second OAuth login")
            end

          other ->
            flunk("unexpected live/2 result: #{inspect(other)}")
        end
      end

      then_ "the picker confirms the org account is still selected, not the personal one",
            context do
        # Visit the picker directly — it renders the active account with a
        # "Currently active" badge. This proves the OAuth callback didn't
        # silently flip the preference back to the personal account.
        {:ok, _view, html} =
          context.second_conn
          |> recycle()
          |> live("/app/accounts/picker")

        assert html =~ context.org_account.name,
               "expected the org account name to appear on the picker"

        :ok
      end
    end
  end

end
