defmodule CodeMySpecSpex.Story602.Criterion5364Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5364 — First signup pre-selects the personal account as active.

  When a brand-new user signs up via OAuth for the first time, the callback
  should not only create a personal account but also pre-select it as the
  active account. The user should not have to visit the account picker before
  reaching authenticated routes.

  Observable through the public surface: after the callback, navigating to
  a route protected by require_active_account succeeds (no picker redirect).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers


  spex "First signup pre-selects the personal account as active" do
    scenario "new Google user lands on an account-protected page without hitting the picker" do
      given_ "a Google OAuth callback is prepared for a brand-new email", context do
        unique = System.unique_integer([:positive])

        user_claims = %{
          "sub" => "google-sub-5364-#{unique}",
          "email" => "new-google-5364-#{unique}@example.com",
          "email_verified" => true,
          "name" => "Google Preselect Test"
        }

        cassette_name = "google_5364_#{unique}"
        OAuthHelpers.build_google_cassette!(cassette_name, user_claims)

        {:ok, Map.merge(context, %{cassette_name: cassette_name, user_claims: user_claims})}
      end

      when_ "the Google OAuth callback completes and the user follows the redirect", context do
        callback_conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            context.cassette_name,
            "google-state-5364"
          )

        {:ok, Map.put(context, :callback_conn, callback_conn)}
      end

      then_ "the callback redirects to onboarding, not the account picker", context do
        destination = redirected_to(context.callback_conn)

        assert destination in ["/app/onboarding", "/app", "/"],
               "expected redirect to onboarding after first OAuth signup, " <>
                 "got: #{inspect(destination)}"

        refute destination =~ "picker",
               "expected no account-picker redirect on first signup; " <>
                 "the personal account should already be active"

        :ok
      end

      then_ "the session resolves to the new Google identity on the settings page",
            context do
        user_token = Plug.Conn.get_session(context.callback_conn, :user_token)
        assert user_token != nil, "expected user_token in session after OAuth callback"

        {:ok, _view, html} =
          context.callback_conn
          |> recycle()
          |> live("/app/users/settings")

        assert html =~ context.user_claims["email"],
               "expected /app/users/settings to render the OAuth user's email " <>
                 "after first signup"

        :ok
      end

      then_ "the user reaches an account-protected route without a picker detour",
            context do
        # /app/projects is gated by require_active_account. If the personal
        # account has been pre-selected as the active preference, this LV
        # mounts; if not, the on_mount hook redirects to /app/accounts/picker.
        result =
          context.callback_conn
          |> recycle()
          |> live("/app/projects")

        case result do
          {:ok, _view, _html} ->
            :ok

          {:error, {:live_redirect, %{to: to}}} ->
            if to =~ "picker" do
              flunk(
                "personal account was not pre-selected as active; " <>
                  "got picker redirect to #{inspect(to)}"
              )
            else
              flunk("unexpected live_redirect to #{inspect(to)} after first OAuth signup")
            end

          {:error, {:redirect, %{to: to}}} ->
            if to =~ "picker" do
              flunk(
                "personal account was not pre-selected as active; " <>
                  "got picker redirect to #{inspect(to)}"
              )
            else
              flunk("unexpected redirect to #{inspect(to)} after first OAuth signup")
            end

          other ->
            flunk("unexpected live/2 result: #{inspect(other)}")
        end
      end
    end
  end

end
