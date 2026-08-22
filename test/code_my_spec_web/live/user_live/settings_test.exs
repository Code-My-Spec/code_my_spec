defmodule CodeMySpecWeb.UserLive.SettingsTest do
  use CodeMySpecTest.ConnCase, async: true

  alias CodeMySpec.Integrations.Providers.OpenAI.DeviceAuth
  alias CodeMySpec.Users
  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/app/users/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    # Every provider setup acts on has to be connectable from here, or the
    # credential can only be obtained by someone who knows the /auth/:provider
    # URL by heart. Cloudflare and Resend were reachable but unlinked.
    test "offers every provider setup needs, not just the sign-in ones", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/app/users/settings")

      for {provider, label} <- [
            {"github", "GitHub"},
            {"google", "Google"},
            {"cloudflare", "Cloudflare"},
            {"resend", "Resend"}
          ] do
        assert html =~ "Connect #{label}",
               "expected a connect button for #{label}"

        assert html =~ ~s|href="/auth/#{provider}"|,
               "expected #{label}'s button to point at its OAuth entry point"
      end
    end

    # Cloudflare and Resend are not sign-in providers, and a row that looks
    # exactly like GitHub's invites the assumption that they are.
    test "says what the infrastructure providers are for", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/app/users/settings")

      assert html =~ "point DNS at your server"
      assert html =~ "receive mail at it"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/app/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/app/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  # ChatGPT is the one provider that cannot be connected with a link, and the
  # reason is not ours: its OAuth client is Pi's, whose registered
  # `redirect_uri` is `http://localhost:1455/auth/callback`. A redirect URI is
  # checked against its registration, so a hosted callback of ours is refused
  # before anyone reaches a consent screen.
  #
  # So it gets the device flow — a code typed on OpenAI's own page — and these
  # exist because until they did, the provider was implemented and connectable
  # by nobody. There was a working refresh, a working token exchange, and no way
  # for a person to arrive at either.
  describe "connecting ChatGPT" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture())}
    end

    # One response per call, queued in the order the flow makes them. Nothing
    # decides anything: a stub that branches on the request is a second
    # implementation of the client, and it passes whether or not the real one
    # calls what it meant to.
    defp expect_next(lv, fun) do
      Req.Test.expect(DeviceAuth, fun)
      # The LiveView is its own process and the expectation is owned by this one.
      Req.Test.allow(DeviceAuth, self(), lv.pid)
    end

    defp expect_user_code(lv) do
      expect_next(lv, fn conn ->
        Req.Test.json(conn, %{
          "device_auth_id" => "dev-1",
          "user_code" => "WXYZ-1234",
          "interval" => 1
        })
      end)
    end

    test "is offered on the page like the others", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/app/users/settings")

      assert html =~ "Connect ChatGPT",
             "ChatGPT has to be connectable from here. It was not, and the effect " <>
               "was a provider with a working refresh that no person could reach."
    end

    test "does not offer a redirect link, which OpenAI would refuse", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/app/users/settings")

      refute html =~ ~s|href="/auth/openai"|,
             "a redirect link here would send someone to a callback OpenAI rejects, " <>
               "because the registered redirect_uri is Pi's localhost:1455"
    end

    test "asking to connect shows the code and where to type it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      expect_user_code(lv)

      html = lv |> element("button[phx-click='start_device_auth']") |> render_click()

      assert html =~ "WXYZ-1234", "the code the human types has to be on screen"

      assert html =~ "auth.openai.com/codex/device",
             "a code with no destination strands whoever is holding it"
    end

    test "keeps the code up while OpenAI is still waiting", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      expect_user_code(lv)
      lv |> element("button[phx-click='start_device_auth']") |> render_click()

      # The second call, and only the second: OpenAI still waiting.
      expect_next(lv, fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{})
      end)

      send(lv.pid, :poll_device_auth)

      assert render(lv) =~ "WXYZ-1234",
             "403 is OpenAI still waiting for the human, not a failure. Clearing the " <>
               "prompt on it takes the code away mid-typing."
    end

    test "connects once the human has finished", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      expect_user_code(lv)
      lv |> element("button[phx-click='start_device_auth']") |> render_click()

      # Then the poll, then the exchange — two calls, two responses, in order.
      expect_next(lv, fn conn ->
        Req.Test.json(conn, %{
          "authorization_code" => "auth-code",
          "code_verifier" => "verifier"
        })
      end)

      expect_next(lv, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "access-abc",
          "refresh_token" => "refresh-abc",
          "expires_in" => 3600
        })
      end)

      send(lv.pid, :poll_device_auth)

      html = render(lv)

      assert html =~ "ChatGPT connected", "the person is told it worked"

      refute html =~ "WXYZ-1234",
             "the prompt has to go once it is done, or the page still asks for a code " <>
               "that has already been used"
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Users.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/app/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Users.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Users.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/app/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/app/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Users.get_user_by_email(user.email)
      assert Users.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/app/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/app/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/app/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/app/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Users.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/app/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end

end
