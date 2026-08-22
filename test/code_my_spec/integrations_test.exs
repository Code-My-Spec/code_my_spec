defmodule CodeMySpec.IntegrationsTest do
  use CodeMySpecTest.DataCase, async: true

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
      have_cassette = File.exists?(cassette_path)
      have_env_token = is_binary(System.get_env("TEST_GOOGLE_REFRESH_TOKEN"))

      assert have_cassette or have_env_token,
             """
             missing cassette at #{cassette_path} and no TEST_GOOGLE_REFRESH_TOKEN
             set to record one. See the comment block above this test.
             """

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

  describe "a login must not downgrade a richer integration" do
    # The bug this covers, end to end: a user connects Google for provisioning
    # (offline access, adwords scope, refresh token), then later signs in with
    # Google. The login flow deliberately drops `prompt=consent` and asks only
    # for `email profile`, so Google returns a response with no refresh_token —
    # which used to be written straight over the good one. The integration then
    # had no way to renew and died at its next expiry.
    setup %{scope: scope} do
      {:ok, _} =
        create_test_integration(scope, :google,
          access_token: "provisioning-token",
          refresh_token: "the-only-way-to-renew",
          granted_scopes: ["email", "profile", "https://www.googleapis.com/auth/adwords"],
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      # Exactly what Google returns for a sign-in: no refresh_token, narrow scope.
      login_token = %{
        "access_token" => "login-token",
        "expires_in" => 3600,
        "scope" => "openid email profile"
      }

      %{login_token: login_token}
    end

    test "a login response with no refresh token leaves the stored one intact",
         %{scope: scope, login_token: login_token} do
      Integrations.save_integration(scope, :google, login_token, %{
        provider_user_id: "u1",
        email: "a@b.c",
        name: "A"
      })

      {:ok, stored} = Integrations.get_integration(scope, :google)

      assert stored.refresh_token == "the-only-way-to-renew",
             "signing in erased the refresh token, leaving the grant unable to renew"
    end

    test "the narrower login scopes do not erase what was already granted",
         %{scope: scope, login_token: login_token} do
      Integrations.save_integration(scope, :google, login_token, %{
        provider_user_id: "u1",
        email: "a@b.c",
        name: "A"
      })

      {:ok, stored} = Integrations.get_integration(scope, :google)

      assert "https://www.googleapis.com/auth/adwords" in stored.granted_scopes,
             "a sign-in reported the grant no longer has scopes it still has"
    end

    test "the fresher access token is still taken", %{scope: scope, login_token: login_token} do
      Integrations.save_integration(scope, :google, login_token, %{
        provider_user_id: "u1",
        email: "a@b.c",
        name: "A"
      })

      {:ok, stored} = Integrations.get_integration(scope, :google)
      assert stored.access_token == "login-token"
    end

    test "a first connection still stores what the provider returned", %{scope: scope} do
      Integrations.save_integration(
        scope,
        :cloudflare,
        %{
          "access_token" => "cf-token",
          "refresh_token" => "cf-refresh",
          "expires_in" => 3600,
          "scope" => "zone.read"
        },
        %{provider_user_id: "u1", email: nil, name: "CF"}
      )

      {:ok, stored} = Integrations.get_integration(scope, :cloudflare)

      assert stored.refresh_token == "cf-refresh"
      assert stored.granted_scopes == ["zone.read"]
    end
  end

  describe "fetch_access_token/2" do
    test "returns the stored token when it is comfortably valid", %{scope: scope} do
      {:ok, _} =
        create_test_integration(scope, :google,
          access_token: "still-good",
          refresh_token: "rt",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      assert {:ok, "still-good"} = Integrations.fetch_access_token(scope, :google)
    end

    # The whole point of the margin. Checking against the exact expiry hands
    # back a token that dies inside the request that used it — a failure that
    # depends on timing and shows up under load.
    test "treats a token expiring within the margin as stale", %{scope: scope} do
      {:ok, integration} =
        create_test_integration(scope, :google,
          access_token: "about-to-die",
          refresh_token: "rt",
          expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
        )

      refute Integrations.fresh?(integration),
             "a token with 30 seconds left is not fresh enough to start a request with"
    end

    test "a token past the margin but not yet expired is still fresh", %{scope: scope} do
      {:ok, integration} =
        create_test_integration(scope, :google,
          access_token: "fine",
          refresh_token: "rt",
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        )

      assert Integrations.fresh?(integration)
    end

    # GitHub's user tokens carry no refresh token and are stored with an expiry
    # a year out. Demanding a reconnect for those would break every GitHub
    # call, so "no refresh token" must not by itself mean "reauthorize".
    test "returns a long-lived token that has no refresh token", %{scope: scope} do
      {:ok, _} =
        create_test_integration(scope, :github,
          access_token: "gho_long_lived",
          refresh_token: nil,
          expires_at: DateTime.add(DateTime.utc_now(), 365 * 24 * 3600, :second)
        )

      assert {:ok, "gho_long_lived"} = Integrations.fetch_access_token(scope, :github)
    end

    # Nothing to renew with, so the only honest answer is "reconnect" —
    # more useful than a 401 surfacing from somewhere deeper.
    test "asks for reauthorization when expired with no refresh token", %{scope: scope} do
      {:ok, _} =
        create_test_integration(scope, :github,
          access_token: "gho_dead",
          refresh_token: nil,
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      assert {:error, :reauthorize_required} = Integrations.fetch_access_token(scope, :github)
    end

    test "returns :not_found when the provider was never connected", %{scope: scope} do
      assert {:error, :not_found} = Integrations.fetch_access_token(scope, :google)
    end

    # The rotation guard. Resend issues a new refresh token on every refresh
    # and invalidates the old one, so a second refresh that did not need to
    # happen spends a token somebody else is now relying on. `refresh_serialized`
    # re-reads under the row lock precisely so the second caller sees the first
    # caller's result instead of refreshing again.
    #
    # The lock itself is not exercised here: every process in the Ecto sandbox
    # shares one connection, so `FOR UPDATE` cannot block and a concurrency
    # test would pass without proving anything. What is proven is the re-check
    # that makes holding the lock worthwhile.
    test "a second call after a refresh does not refresh again", %{scope: scope} do
      {:ok, _} =
        create_test_integration(scope, :google,
          access_token: "expired",
          refresh_token: "rt-original",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      {:ok, calls} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        Agent.update(calls, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "renewed",
            "refresh_token" => "rt-rotated",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end

      with_assent_plug(plug, fn ->
        assert {:ok, "renewed"} = Integrations.fetch_access_token(scope, :google)
        assert {:ok, "renewed"} = Integrations.fetch_access_token(scope, :google)
      end)

      assert Agent.get(calls, & &1) == 1,
             "the token endpoint was hit more than once — a rotating refresh token would already be spent"
    end

    # Rotation only helps if the new value is what gets stored. Keeping the old
    # one leaves the grant one refresh away from presenting a spent token.
    test "the rotated refresh token replaces the one that was used", %{scope: scope} do
      {:ok, _} =
        create_test_integration(scope, :google,
          access_token: "expired",
          refresh_token: "rt-original",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "renewed",
            "refresh_token" => "rt-rotated",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end

      with_assent_plug(plug, fn ->
        assert {:ok, "renewed"} = Integrations.fetch_access_token(scope, :google)
      end)

      {:ok, stored} = Integrations.get_integration(scope, :google)
      assert stored.refresh_token == "rt-rotated"
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

  describe "GitHub login cassette shape (one-time recording)" do
    # Records real GitHub /user and /user/emails responses into
    # test/cassettes/oauth/github_login_shape.json — captures the actual
    # response shape (which fields GitHub returns, what types, etc).
    # PII fields are scrubbed to placeholders; spex tests load this template
    # and inject per-scenario user_json + emails_json. The token-exchange
    # interaction is prepended manually because we'd need a fresh OAuth
    # auth_code from the browser flow to record it for real, and the
    # response shape is trivial (access_token + scope + token_type).
    #
    # To re-record:
    #   1. delete test/cassettes/oauth/github_login_shape.json
    #   2. set TEST_GITHUB_ACCESS_TOKEN to a real OAuth access_token
    #      (read from integrations table for a real user)
    #   3. mix test --only record_github_login_shape
    @tag :record_github_login_shape
    test "captures /user and /user/emails responses, prepends synthetic token interaction" do
      access_token =
        System.get_env("TEST_GITHUB_ACCESS_TOKEN") ||
          flunk("TEST_GITHUB_ACCESS_TOKEN required to re-record the shape cassette")

      auth = [{"authorization", "Bearer #{access_token}"}, {"accept", "application/json"}]

      with_cassette "github_login_shape", github_shape_cassette_opts(), fn plug ->
        # GET /user
        {:ok, _} = Req.get(plug: plug, url: "https://api.github.com/user", headers: auth)
        # GET /user/emails
        {:ok, _} = Req.get(plug: plug, url: "https://api.github.com/user/emails", headers: auth)
      end

      shape_path = Path.join(@cassette_dir, "github_login_shape.json")
      shape = shape_path |> File.read!() |> Jason.decode!()

      # Prepend a synthetic token-exchange interaction so the shape file is
      # self-contained. Spex test-time helper replaces the access_token with
      # a placeholder anyway; what matters is the response shape Assent
      # parses (`access_token`, `scope`, `token_type`).
      token_interaction = %{
        "recorded_at" => "2026-04-25T23:00:00Z",
        "request" => %{
          "method" => "POST",
          "uri" => "https://github.com/login/oauth/access_token",
          "query_string" => "",
          "headers" => %{"content-type" => ["application/x-www-form-urlencoded"]},
          "body_type" => "text",
          "body" => "<filtered>"
        },
        "response" => %{
          "status" => 200,
          "headers" => %{"content-type" => ["application/json; charset=utf-8"]},
          "body_type" => "json",
          "body_json" => %{
            "access_token" => "<TEST_ACCESS_TOKEN_PLACEHOLDER>",
            "scope" => "read:user,user:email",
            "token_type" => "bearer"
          }
        }
      }

      shape =
        update_in(shape, ["interactions"], fn interactions -> [token_interaction | interactions] end)

      File.write!(shape_path, Jason.encode!(shape, pretty: true))

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

  # GitHub /user response is an object full of PII (id, login, name, email,
  # avatar_url, etc.); /user/emails returns an array of email objects. The
  # spex test-time helper replaces the entire response body with per-test
  # user_json / emails_json, but we still scrub here so the committed shape
  # file never holds real account data.
  # The OpenAI refresh shape, for story 1018's criterion 2822.
  #
  # Not recorded yet, and cannot be until a ChatGPT grant exists —
  # `~/.pi/agent/auth.json` holds only `anthropic`, because `/login` is a TUI
  # slash command nobody has run for ChatGPT. Hand-writing the JSON would be
  # manufacturing a recording, so the criterion stubs the refusal explicitly and
  # this waits for a real grant.
  #
  # To record:
  #   1. run `/login` in Pi and choose OpenAI (ChatGPT Plus/Pro)
  #   2. read the refresh token out of ~/.pi/agent/auth.json ("openai-codex")
  #   3. TEST_OPENAI_REFRESH_TOKEN=<token> mix test --only record_openai_refresh_shape
  #
  # What matters in the shape is what Assent parses back: `access_token`,
  # `refresh_token` (OpenAI rotates it on every refresh) and `expires_in`.
  @tag :record_openai_refresh_shape
  test "captures the OpenAI token refresh response shape" do
    refresh_token =
      System.get_env("TEST_OPENAI_REFRESH_TOKEN") ||
        flunk("TEST_OPENAI_REFRESH_TOKEN required to record the OpenAI refresh shape")

    with_cassette "openai_refresh_shape", openai_shape_cassette_opts(), fn plug ->
      {:ok, _} =
        Req.post(
          plug: plug,
          url: "https://auth.openai.com/oauth/token",
          form: [
            grant_type: "refresh_token",
            refresh_token: refresh_token,
            client_id: "app_EMoamEEZ73f0CkXaXp7hrann"
          ]
        )
    end
  end

  defp openai_shape_cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      # Every token in the response is a live credential for somebody's
      # subscription. The shape is the point; the values must not survive.
      filter_response_body: fn body ->
        body
        |> String.replace(~r/"access_token":"[^"]*"/, ~s("access_token":"recorded-access"))
        |> String.replace(~r/"refresh_token":"[^"]*"/, ~s("refresh_token":"recorded-refresh"))
        |> String.replace(~r/"id_token":"[^"]*"/, ~s("id_token":"recorded-id"))
      end
    ]
  end

  defp github_shape_cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie", "x-github-request-id", "x-ratelimit-remaining"],
      # The whole /user object body is PII. Easier to wholesale-replace via
      # filter_response than try to redact every PII field with regex.
      filter_response: &scrub_github_response/1
    ]
  end

  defp scrub_github_response(%{"body_json" => body} = response) when is_map(body) do
    # /user response is a single user object — replace any string field that
    # looks like PII; preserve numeric/boolean fields and structural keys.
    %{response | "body_json" => scrub_github_user(body)}
  end

  defp scrub_github_response(%{"body_json" => list} = response) when is_list(list) do
    # /user/emails response is an array of email objects.
    %{response | "body_json" => Enum.map(list, &scrub_github_email/1)}
  end

  defp scrub_github_response(response), do: response

  @github_pii_fields ~w(login name email avatar_url html_url url node_id gravatar_id
    bio blog company location twitter_username notification_email
    followers_url following_url gists_url starred_url subscriptions_url
    organizations_url repos_url events_url received_events_url)

  defp scrub_github_user(map) when is_map(map) do
    Enum.reduce(@github_pii_fields, map, &scrub_pii_field/2)
  end

  defp scrub_pii_field(key, acc) do
    do_scrub_pii_field(Map.get(acc, key), key, acc)
  end

  defp do_scrub_pii_field(value, key, acc) when is_binary(value),
    do: Map.put(acc, key, "<TEST_#{String.upcase(key)}_PLACEHOLDER>")

  defp do_scrub_pii_field(_value, _key, acc), do: acc

  defp scrub_github_email(%{"email" => _} = entry) do
    Map.put(entry, "email", "<TEST_EMAIL_PLACEHOLDER>")
  end

  defp scrub_github_email(entry), do: entry

  defp with_assent_plug(plug, fun) do
    previous = Application.get_env(:assent, :http_adapter)
    Application.put_env(:assent, :http_adapter, {Assent.HTTPAdapter.Req, [plug: plug]})

    ExUnit.Callbacks.on_exit(fn -> restore_assent_adapter(previous) end)
    fun.()
  end

  defp restore_assent_adapter(nil), do: Application.delete_env(:assent, :http_adapter)
  defp restore_assent_adapter(adapter), do: Application.put_env(:assent, :http_adapter, adapter)
end
