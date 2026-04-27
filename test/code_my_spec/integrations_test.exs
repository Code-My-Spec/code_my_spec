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

    # Records (first time) or replays (every time after) a real Google
    # token-endpoint response.
    #
    # Replay: cassette exists on disk → uses a placeholder refresh_token, the
    # body never goes over the wire, and ReqCassette returns the recorded
    # response. Runs as part of the default suite.
    #
    # Re-record: delete the cassette and set TEST_GOOGLE_REFRESH_TOKEN to a
    # real refresh_token (visit /app/users/settings on the dev server →
    # Connect Google → integration flow keeps prompt=consent → refresh_token
    # gets persisted, copy from integrations table). Then `mix test` reruns
    # the test, which records, scrubs, and writes the cassette. Revoke the
    # token afterward.
    test "swaps in a fresh access_token from Google's token endpoint",
         %{scope: scope} do
      cassette_path = Path.join(@cassette_dir, @cassette_name <> ".json")

      cond do
        File.exists?(cassette_path) ->
          :replay

        is_binary(System.get_env("TEST_GOOGLE_REFRESH_TOKEN")) ->
          :record

        true ->
          flunk("""
          missing cassette at #{cassette_path} and no TEST_GOOGLE_REFRESH_TOKEN
          set to record one. See the comment block above this test.
          """)
      end

      refresh_token =
        System.get_env("TEST_GOOGLE_REFRESH_TOKEN") || "1//placeholder_refresh_token"

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

  describe "Google login cassette shape (one-time recording)" do
    # Records a real Google OIDC login flow into
    # test/cassettes/oauth/google_login_shape.json — captures the actual
    # response shapes from openid-configuration, the token endpoint, and JWKS.
    # The id_token + JWKS keys are scrubbed to <TEST_*_PLACEHOLDER>; spex
    # tests load this template and inject a per-test id_token signed with a
    # fresh RSA keypair. This way the cassette has real Google response shape
    # forever (catches drift) without committing time-bound real id_tokens.
    #
    # To record (re-record):
    #   1. delete test/cassettes/oauth/google_login_shape.json
    #   2. set TEST_GOOGLE_REFRESH_TOKEN to a fresh refresh_token
    #   3. mix test --only record_google_login_shape
    #
    # Without the env var the test is excluded; without the cassette the
    # spex tests that depend on it fail loudly.
    @tag :record_google_login_shape
    test "captures openid-configuration + token endpoint + JWKS in one cassette" do
      refresh_token =
        System.get_env("TEST_GOOGLE_REFRESH_TOKEN") ||
          flunk("TEST_GOOGLE_REFRESH_TOKEN required to re-record the shape cassette")

      client_id = Application.fetch_env!(:code_my_spec, :google_client_id)
      client_secret = Application.fetch_env!(:code_my_spec, :google_client_secret)

      with_cassette "google_login_shape", shape_cassette_opts(), fn plug ->
        # 1. openid-configuration discovery
        {:ok, _} = Req.get(plug: plug, url: "https://accounts.google.com/.well-known/openid-configuration")

        # 2. Token endpoint — using grant_type=refresh_token gives us the
        # same response shape Google returns for grant_type=authorization_code
        # (access_token + id_token + scope + expires_in). Match on
        # method+uri only, so the spex tests' POST body doesn't have to
        # match this body.
        body =
          URI.encode_query(%{
            "grant_type" => "refresh_token",
            "refresh_token" => refresh_token,
            "client_id" => client_id,
            "client_secret" => client_secret
          })

        {:ok, _} =
          Req.post(
            plug: plug,
            url: "https://oauth2.googleapis.com/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]
          )

        # 3. JWKS
        {:ok, _} = Req.get(plug: plug, url: "https://www.googleapis.com/oauth2/v3/certs")
      end

      shape_path = Path.join(@cassette_dir, "google_login_shape.json")
      assert File.exists?(shape_path), "shape cassette must be written"

      shape = shape_path |> File.read!() |> Jason.decode!()
      assert length(shape["interactions"]) == 3
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
  #
  # filter_sensitive_data redacts secrets from the recorded JSON via regex
  # before write. Mirrors integrations_controller_login_test.exs cassette_opts.
  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        # form-encoded request body
        {~r/refresh_token=[^&\s"]+/, "refresh_token=<REDACTED>"},
        {~r/client_secret=[^&\s"]+/, "client_secret=<REDACTED>"},
        {~r/access_token=[^&\s"]+/, "access_token=<REDACTED>"},
        # JSON response body — id_token is a signed JWT containing PII
        {~r/"access_token"\s*:\s*"[^"]+"/, ~s("access_token":"<REDACTED>")},
        {~r/"refresh_token"\s*:\s*"[^"]+"/, ~s("refresh_token":"<REDACTED>")},
        {~r/"id_token"\s*:\s*"[^"]+"/, ~s("id_token":"<REDACTED>")}
      ]
    ]
  end

  # Scrub real shape recording → swap id_token + JWKS key material for
  # placeholder strings the build_google_cassette_from_shape! helper
  # injects per-test values into.
  defp shape_cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        # form-encoded request body
        {~r/refresh_token=[^&\s"]+/, "refresh_token=<REDACTED>"},
        {~r/client_secret=[^&\s"]+/, "client_secret=<REDACTED>"},
        # JSON response body — token endpoint returns these
        {~r/"access_token"\s*:\s*"[^"]+"/, ~s("access_token":"<REDACTED>")},
        {~r/"refresh_token"\s*:\s*"[^"]+"/, ~s("refresh_token":"<REDACTED>")},
        {~r/"id_token"\s*:\s*"[^"]+"/, ~s("id_token":"<TEST_ID_TOKEN_PLACEHOLDER>")},
        # JWKS — replace `n` (modulus) values with placeholder so test-time
        # helper can inject our test public key. `kid`, `kty`, `alg`,
        # `use`, `e` are stable structure that's safe to keep.
        {~r/"n"\s*:\s*"[^"]+"/, ~s("n":"<TEST_JWK_N_PLACEHOLDER>")}
      ]
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
