defmodule CodeMySpec.IntegrationsTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.{UsersFixtures}
  import ReqCassette

  alias CodeMySpec.Integrations
  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.Users.Scope

  @cassette_dir "test/cassettes/oauth"

  setup do
    user = user_fixture()
    scope = %Scope{user: user}

    {:ok, scope: scope, user: user}
  end

  describe "authorize_url/1" do
    test "generates GitHub authorization URL with session params" do
      assert {:ok, %{url: url, session_params: session_params}} =
               Integrations.authorize_url(:github)

      assert is_binary(url)
      assert String.starts_with?(url, "https://github.com")
      assert is_map(session_params)
    end

    test "returns error for unsupported provider" do
      assert {:error, :unsupported_provider} = Integrations.authorize_url(:unsupported)
    end
  end

  describe "handle_callback/4" do
    test "creates integration on successful OAuth callback", %{scope: scope} do
      # Note: This test would require mocking Assent.Strategy.Github.callback/2
      # For now, we'll test the upsert_integration path directly
      token_attrs = %{
        access_token: "gho_test_token",
        refresh_token: nil,
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second),
        granted_scopes: ["user:email", "repo"],
        provider_metadata: %{
          provider_user_id: "12345",
          email: "test@example.com",
          name: "Test User"
        }
      }

      assert {:ok, integration} =
               Integrations.IntegrationRepository.upsert_integration(scope, :github, token_attrs)

      assert integration.provider == :github
      assert integration.user_id == scope.user.id
      assert integration.access_token == "gho_test_token"
    end
  end

  describe "get_integration/2" do
    test "returns integration when it exists", %{scope: scope} do
      {:ok, created} = create_test_integration(scope, :github)

      assert {:ok, integration} = Integrations.get_integration(scope, :github)
      assert integration.id == created.id
      assert integration.provider == :github
    end

    test "returns error when integration doesn't exist", %{scope: scope} do
      assert {:error, :not_found} = Integrations.get_integration(scope, :gitlab)
    end
  end

  describe "list_integrations/1" do
    test "returns all integrations for user", %{scope: scope} do
      {:ok, _} = create_test_integration(scope, :github)

      integrations = Integrations.list_integrations(scope)

      assert length(integrations) == 1
      assert Enum.all?(integrations, fn i -> i.user_id == scope.user.id end)
    end

    test "returns empty list when no integrations exist", %{scope: scope} do
      assert [] = Integrations.list_integrations(scope)
    end
  end

  describe "delete_integration/2" do
    test "deletes integration when it exists", %{scope: scope} do
      {:ok, _} = create_test_integration(scope, :github)

      assert {:ok, %Integration{}} = Integrations.delete_integration(scope, :github)
      assert {:error, :not_found} = Integrations.get_integration(scope, :github)
    end

    test "returns error when integration doesn't exist", %{scope: scope} do
      assert {:error, :not_found} = Integrations.delete_integration(scope, :gitlab)
    end
  end

  describe "connected?/2" do
    test "returns true when integration exists", %{scope: scope} do
      {:ok, _} = create_test_integration(scope, :github)

      assert Integrations.connected?(scope, :github)
    end

    test "returns false when integration doesn't exist", %{scope: scope} do
      refute Integrations.connected?(scope, :gitlab)
    end
  end

  describe "refresh_token/2" do
    test "swaps in a fresh access_token from the provider's token endpoint",
         %{scope: scope} do
      # Backdate the existing integration to simulate an expired token.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      {:ok, _original} =
        create_test_integration(scope, :google,
          access_token: "old_access_token",
          refresh_token: "rt_existing",
          expires_at: past
        )

      cassette_name = "google_refresh_success_#{System.unique_integer([:positive])}"

      build_google_token_cassette!(cassette_name, %{
        "access_token" => "fresh_access_token",
        "expires_in" => 3599,
        "scope" => "https://www.googleapis.com/auth/analytics.edit",
        "token_type" => "Bearer"
      })

      with_cassette cassette_name, cassette_opts(), fn plug ->
        with_assent_plug(plug, fn ->
          assert {:ok, refreshed} = Integrations.refresh_token(scope, :google)

          assert refreshed.access_token == "fresh_access_token"
          # Provider didn't rotate the refresh_token — keep the old one.
          assert refreshed.refresh_token == "rt_existing"
          # New expiry is in the future; the persisted record is no longer expired.
          assert DateTime.compare(refreshed.expires_at, DateTime.utc_now()) == :gt
          # Scope from the response is parsed and persisted.
          assert "https://www.googleapis.com/auth/analytics.edit" in refreshed.granted_scopes
        end)
      end
    end

    test "uses the new refresh_token when the provider rotates it", %{scope: scope} do
      {:ok, _original} =
        create_test_integration(scope, :google,
          access_token: "old",
          refresh_token: "rt_old"
        )

      cassette_name = "google_refresh_rotated_#{System.unique_integer([:positive])}"

      build_google_token_cassette!(cassette_name, %{
        "access_token" => "fresh_access_token",
        "refresh_token" => "rt_new",
        "expires_in" => 3599,
        "token_type" => "Bearer"
      })

      with_cassette cassette_name, cassette_opts(), fn plug ->
        with_assent_plug(plug, fn ->
          assert {:ok, refreshed} = Integrations.refresh_token(scope, :google)
          assert refreshed.refresh_token == "rt_new"
        end)
      end
    end

    test "returns :no_refresh_token when the integration was stored without one",
         %{scope: scope} do
      {:ok, _} =
        create_test_integration(scope, :google,
          access_token: "ok",
          refresh_token: nil
        )

      assert {:error, :no_refresh_token} = Integrations.refresh_token(scope, :google)
    end

    test "returns :not_found when the user has no integration for the provider",
         %{scope: scope} do
      assert {:error, :not_found} = Integrations.refresh_token(scope, :google)
    end
  end

  # Test Helpers

  defp create_test_integration(scope, provider, overrides \\ []) do
    defaults = [
      access_token: "test_token_#{:rand.uniform(10000)}",
      refresh_token: "test_refresh_#{:rand.uniform(10000)}",
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second),
      granted_scopes: ["user:email", "repo"],
      provider_metadata: %{
        provider_user_id: "test_user_#{:rand.uniform(10000)}",
        email: "test@example.com",
        name: "Test User"
      }
    ]

    attrs = defaults |> Keyword.merge(overrides) |> Map.new()

    Integrations.IntegrationRepository.upsert_integration(scope, provider, attrs)
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :replay,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"]
    ]
  end

  # Writes a single-interaction cassette for POST https://oauth2.googleapis.com/token
  # returning the supplied JSON body. The actual refresh_token / client creds in
  # the request body are ignored (match_requests_on is [:method, :uri]).
  defp build_google_token_cassette!(cassette_name, body_json) do
    cassette = %{
      "version" => "2.0",
      "interactions" => [
        %{
          "recorded_at" => "2026-04-25T23:00:01Z",
          "request" => %{
            "method" => "POST",
            "uri" => "https://oauth2.googleapis.com/token",
            "query_string" => "",
            "headers" => %{"content-type" => ["application/x-www-form-urlencoded"]},
            "body_type" => "text",
            "body" => "<filtered>"
          },
          "response" => %{
            "status" => 200,
            "headers" => %{"content-type" => ["application/json; charset=utf-8"]},
            "body_type" => "json",
            "body_json" => body_json
          }
        }
      ]
    }

    File.mkdir_p!(@cassette_dir)
    path = Path.join(@cassette_dir, cassette_name <> ".json")
    File.write!(path, Jason.encode!(cassette, pretty: true))
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp with_assent_plug(plug, fun) do
    previous = Application.get_env(:assent, :http_adapter)
    Application.put_env(:assent, :http_adapter, {Assent.HTTPAdapter.Req, [plug: plug]})

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:assent, :http_adapter)
        adapter -> Application.put_env(:assent, :http_adapter, adapter)
      end
    end
  end
end
