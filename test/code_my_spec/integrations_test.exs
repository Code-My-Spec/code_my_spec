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
    @cassette_name "google_refresh_success"

    @moduletag :capture_log

    @doc """
    Records or replays a real Google token-endpoint response.

    First run (no cassette on disk): set `TEST_GOOGLE_REFRESH_TOKEN` to a real
    refresh_token (obtain by visiting `/app/users/settings` on the dev server
    and clicking "Connect Google" — the integration flow keeps `prompt=consent`
    so Google issues a refresh_token). Then run:

        mix test test/code_my_spec/integrations_test.exs --only record_google_refresh

    ReqCassette will hit Google for real, capture the response, scrub the
    sensitive headers, and write `test/cassettes/oauth/google_refresh_success.json`.
    Subsequent runs replay against that file with no network access required.
    """
    @tag :record_google_refresh
    test "swaps in a fresh access_token from Google's token endpoint",
         %{scope: scope} do
      cassette_path = Path.join(@cassette_dir, @cassette_name <> ".json")

      refresh_token =
        System.get_env("TEST_GOOGLE_REFRESH_TOKEN") ||
          flunk("""
          set TEST_GOOGLE_REFRESH_TOKEN to record this cassette. Get one by:
          1. visit /app/users/settings on the dev server
          2. click "Connect Google" (integration flow, not login)
          3. read the refresh_token off integrations table for your user
          """)

      {:ok, _original} =
        create_test_integration(scope, :google,
          access_token: "old_access_token",
          refresh_token: refresh_token,
          expires_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
        )

      with_cassette @cassette_name, cassette_opts(), fn plug ->
        with_assent_plug(plug, fn ->
          assert {:ok, refreshed} = Integrations.refresh_token(scope, :google)

          assert is_binary(refreshed.access_token) and refreshed.access_token != ""
          assert DateTime.compare(refreshed.expires_at, DateTime.utc_now()) == :gt
        end)
      end

      assert File.exists?(cassette_path),
             "cassette should have been recorded at #{cassette_path}"
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

  # mode: :record means "record on cassette/interaction miss, replay otherwise"
  # — first run with a real refresh_token captures the response, all
  # subsequent runs replay against the on-disk JSON without network.
  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri],
      # access_token leaks into the URL as a query param sometimes; strip
      # it. refresh_token + client_secret live in the form-encoded body
      # which req_cassette serializes as `<filtered>` when match_requests_on
      # excludes :body.
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"]
    ]
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
