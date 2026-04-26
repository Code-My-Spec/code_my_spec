defmodule CodeMySpecSpex.Story602.Criterion5363Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5363 — Legacy OAuth user without a personal account is healed on
  next authenticated request.

  A user who signed up via OAuth before the ensure_personal_account fix was
  applied may have a valid session but zero accounts. The `require_active_account`
  LiveView on_mount hook contains a self-heal: when a logged-in user has no
  accounts at all, it calls ensure_personal_account/1 on the spot and sets the
  new account as active — without bouncing the user to the picker.

  This is observable through the public surface: the user navigates to a route
  protected by require_active_account (e.g. /app/projects) and the page renders
  rather than redirecting to the account picker or showing an error.
  """

  use CodeMySpecSpex.Case

  # The :require_active_account live_session lives on CodeMySpecWeb, not the
  # local web — override the endpoint so live/2 targets the right server.
  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures


  spex "Legacy OAuth user without a personal account is healed on next authenticated request" do
    scenario "accountless user reaches /app/projects without being sent to the picker" do
      given_ "a user exists with no accounts at all (simulating a legacy OAuth user)", context do
        # user_fixture creates a user record with no accounts and no account
        # preferences. This mirrors the state of an OAuth user registered
        # before ensure_personal_account was wired into the callback.
        user = Fixtures.user_fixture()

        {:ok, Map.put(context, :user, user)}
      end

      when_ "the user makes an authenticated request to a require_active_account-protected route",
            context do
        # Log in by injecting the session token directly — the same mechanism
        # as UserAuth.log_in_user/3, driven through the test conn.
        token = Fixtures.generate_user_session_token(context.user)

        conn =
          build_conn()
          |> Phoenix.ConnTest.init_test_session(%{})
          |> Plug.Conn.put_session(:user_token, token)

        # /app/projects uses the :require_active_account live_session.
        # With no accounts, the self-heal should fire and allow the mount to
        # continue rather than halting with a redirect to the picker.
        result = Phoenix.LiveViewTest.live(conn, "/app/projects")

        {:ok, Map.put(context, :live_result, result)}
      end

      then_ "the LiveView mounts successfully rather than redirecting to the account picker",
            context do
        case context.live_result do
          {:ok, _view, _html} ->
            # Mount succeeded — self-heal fired and the user can see /app/projects.
            :ok

          {:error, {:live_redirect, %{to: to}}} ->
            flunk(
              "expected self-heal to allow the mount but got a live_redirect to #{inspect(to)}"
            )

          {:error, {:redirect, %{to: to}}} ->
            flunk(
              "expected self-heal to allow the mount but got a redirect to #{inspect(to)}"
            )

          other ->
            flunk("unexpected live/2 result: #{inspect(other)}")
        end
      end
    end
  end

end
