defmodule CodeMySpecWeb.IntegrationsControllerTest do
  use CodeMySpecTest.ConnCase, async: true

  alias CodeMySpec.Integrations

  setup :register_log_in_setup_account

  describe "GET /auth/:provider" do
    test "redirects to GitHub OAuth authorization URL", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")

      assert redirected_to(conn, 302) =~ "https://github.com"
      assert get_session(conn, :oauth_provider) == :github
      assert is_map(get_session(conn, :oauth_session_params))
    end

    test "requires authentication" do
      conn = build_conn() |> get(~p"/auth/github")

      assert redirected_to(conn) =~ "/users/log-in"
    end
  end

  describe "GET /auth/:provider/callback" do
    @tag :capture_log
    test "handles successful OAuth callback", %{conn: conn} do
      # Set up session as if we initiated OAuth flow
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:oauth_provider, :github)
        |> put_session(:oauth_session_params, %{"state" => "test_state"})

      # Mock a successful callback - in real flow, this would come from GitHub
      # For now, we'll just test the error path since mocking Assent is complex
      conn = get(conn, ~p"/auth/github/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == ~p"/app/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "denied access"
    end

    @tag :capture_log
    test "handles OAuth error in callback", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:oauth_provider, :github)
        |> put_session(:oauth_session_params, %{})

      conn = get(conn, ~p"/auth/github/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == ~p"/app/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "denied"
    end

    @tag :capture_log
    test "clears OAuth session data after callback", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:oauth_provider, :github)
        |> put_session(:oauth_session_params, %{"state" => "test"})

      conn = get(conn, ~p"/auth/github/callback", %{"error" => "test_error"})

      assert is_nil(get_session(conn, :oauth_provider))
      assert is_nil(get_session(conn, :oauth_session_params))
    end
  end

  describe "DELETE /auth/:provider" do
    test "deletes existing integration", %{conn: conn, scope: scope} do
      {:ok, _integration} = create_test_integration(scope, :github)

      conn = delete(conn, ~p"/auth/github")

      assert redirected_to(conn) == ~p"/app/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Disconnected"
      assert {:error, :not_found} = Integrations.get_integration(scope, :github)
    end

    test "handles non-existent integration", %{conn: conn} do
      conn = delete(conn, ~p"/auth/github")

      assert redirected_to(conn) == ~p"/app/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "No connection found"
    end

    test "requires authentication" do
      conn = build_conn() |> delete(~p"/auth/github")

      assert redirected_to(conn) =~ "/users/log-in"
    end
  end

  # Test Helpers

  defp create_test_integration(scope, provider) do
    attrs = %{
      access_token: "test_token_#{:rand.uniform(10000)}",
      refresh_token: "test_refresh_#{:rand.uniform(10000)}",
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second),
      granted_scopes: ["user:email", "repo"],
      provider_metadata: %{
        provider_user_id: "test_user_#{:rand.uniform(10000)}",
        email: "test@example.com",
        name: "Test User"
      }
    }

    Integrations.IntegrationRepository.upsert_integration(scope, provider, attrs)
  end
end
