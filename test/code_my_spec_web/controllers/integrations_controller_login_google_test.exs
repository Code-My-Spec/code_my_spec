defmodule CodeMySpecWeb.IntegrationsControllerLoginGoogleTest do
  @moduledoc """
  Google OIDC login flow end-to-end through `IntegrationsController.callback/2`.

  Google's flow is OpenID Connect, so the callback exchanges the code for an
  ID token (JWT), validates its signature against the JWKS, and extracts user
  claims from the verified token. To replay this offline we need three
  cassette interactions and a JWT whose signature actually verifies:

    1. GET https://accounts.google.com/.well-known/openid-configuration
    2. POST https://oauth2.googleapis.com/token            (returns the ID token)
    3. GET  https://www.googleapis.com/oauth2/v3/certs     (returns the JWKS)

  The ID token's `exp` claim must be in the future, so the cassette is
  rebuilt from a freshly-generated RSA keypair on every test run rather than
  committed as a static fixture.
  """

  use CodeMySpecTest.ConnCase, async: false

  import ReqCassette

  alias CodeMySpec.Accounts
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope

  @cassette_dir "test/cassettes/oauth"
  @cassette_name "google_login_new_user"
  @cassette_path Path.join(@cassette_dir, @cassette_name <> ".json")

  @issuer "https://accounts.google.com"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @jwks_uri "https://www.googleapis.com/oauth2/v3/certs"
  @authorization_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @kid "test-google-key-1"

  describe "GET /auth/google/callback (login flow) — new user" do
    @describetag :capture_log

    test "creates a personal account so the user can pick one in Workspace",
         %{conn: conn} do
      user_claims = %{
        "sub" => "117283400000000000001",
        "email" => "google-fixture@example.com",
        "email_verified" => true,
        "name" => "Google Fixture User",
        "picture" => "https://lh3.googleusercontent.com/a/test-avatar",
        "given_name" => "Google",
        "family_name" => "Fixture"
      }

      build_google_cassette!(user_claims)

      with_cassette @cassette_name, cassette_opts(), fn plug ->
        with_assent_plug(plug, fn ->
          conn =
            conn
            |> Phoenix.ConnTest.init_test_session(%{})
            |> Plug.Conn.put_session(:oauth_provider, :google)
            |> Plug.Conn.put_session(:oauth_session_params, %{state: "google-state"})
            |> Plug.Conn.put_session(:oauth_flow, :login)

          conn =
            get(conn, ~p"/auth/google/callback", %{
              "code" => "google-replay-code",
              "state" => "google-state"
            })

          assert redirected_to(conn) in [~p"/app/onboarding", ~p"/app", ~p"/"]
          assert user_token = Plug.Conn.get_session(conn, :user_token)
          assert {user, _inserted_at} = Users.get_user_by_session_token(user_token)
          assert user.email == "google-fixture@example.com"

          assert Accounts.get_personal_account(Scope.for_user(user)),
                 "expected a personal account to be created for a new Google user"
        end)
      end
    end
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

  # Same Application-env seam as the GitHub test: route Assent's HTTP through
  # ReqCassette's plug for the duration of the call.
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

  # ---- Cassette generation ---------------------------------------------------

  defp build_google_cassette!(user_claims) do
    {pem, n, e} = generate_rsa_keypair()
    client_id = Application.fetch_env!(:code_my_spec, :google_client_id)
    id_token = sign_id_token(pem, user_claims, client_id)
    jwk = public_jwk(n, e)

    cassette = %{
      "version" => "2.0",
      "interactions" => [
        openid_configuration_interaction(),
        token_interaction(id_token),
        jwks_interaction(jwk)
      ]
    }

    File.mkdir_p!(@cassette_dir)
    File.write!(@cassette_path, Jason.encode!(cassette, pretty: true))
    :ok
  end

  defp generate_rsa_keypair do
    rsa_private = :public_key.generate_key({:rsa, 2048, 65537})
    {:RSAPrivateKey, _v, n, e, _d, _p, _q, _e1, _e2, _c, _other} = rsa_private

    pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa_private)])

    {pem, n, e}
  end

  defp sign_id_token(pem, claims, client_id) do
    now = :os.system_time(:second)

    id_token_claims =
      claims
      |> Map.put("iss", @issuer)
      |> Map.put("aud", client_id)
      |> Map.put("azp", client_id)
      |> Map.put("iat", now)
      |> Map.put("exp", now + 3600)

    {:ok, jwt} =
      Assent.JWTAdapter.AssentJWT.sign(
        id_token_claims,
        "RS256",
        pem,
        private_key_id: @kid,
        json_library: Jason
      )

    jwt
  end

  defp public_jwk(n, e) do
    %{
      "kty" => "RSA",
      "alg" => "RS256",
      "use" => "sig",
      "kid" => @kid,
      "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
    }
  end

  defp openid_configuration_interaction do
    %{
      "recorded_at" => "2026-04-25T23:00:00Z",
      "request" => %{
        "method" => "GET",
        "uri" => "https://accounts.google.com/.well-known/openid-configuration",
        "query_string" => "",
        "headers" => %{"accept" => ["application/json"]},
        "body_type" => "text",
        "body" => ""
      },
      "response" => %{
        "status" => 200,
        "headers" => %{
          "cache-control" => ["public, max-age=3600"],
          "content-type" => ["application/json; charset=utf-8"],
          "server" => ["scaffolding on HTTPServer2"]
        },
        "body_type" => "json",
        "body_json" => %{
          "issuer" => @issuer,
          "authorization_endpoint" => @authorization_endpoint,
          "token_endpoint" => @token_endpoint,
          "userinfo_endpoint" => "https://openidconnect.googleapis.com/v1/userinfo",
          "revocation_endpoint" => "https://oauth2.googleapis.com/revoke",
          "jwks_uri" => @jwks_uri,
          "response_types_supported" => [
            "code",
            "token",
            "id_token",
            "code token",
            "code id_token",
            "token id_token",
            "code token id_token",
            "none"
          ],
          "subject_types_supported" => ["public"],
          "id_token_signing_alg_values_supported" => ["RS256"],
          "scopes_supported" => ["openid", "email", "profile"],
          "token_endpoint_auth_methods_supported" => [
            "client_secret_post",
            "client_secret_basic"
          ],
          "claims_supported" => [
            "aud",
            "email",
            "email_verified",
            "exp",
            "family_name",
            "given_name",
            "iat",
            "iss",
            "name",
            "picture",
            "sub"
          ],
          "code_challenge_methods_supported" => ["plain", "S256"],
          "grant_types_supported" => [
            "authorization_code",
            "refresh_token",
            "urn:ietf:params:oauth:grant-type:device_code",
            "urn:ietf:params:oauth:grant-type:jwt-bearer"
          ]
        }
      }
    }
  end

  defp token_interaction(id_token) do
    %{
      "recorded_at" => "2026-04-25T23:00:01Z",
      "request" => %{
        "method" => "POST",
        "uri" => @token_endpoint,
        "query_string" => "",
        "headers" => %{
          "content-type" => ["application/x-www-form-urlencoded"]
        },
        "body_type" => "text",
        "body" => "<filtered>"
      },
      "response" => %{
        "status" => 200,
        "headers" => %{
          "cache-control" => ["no-cache, no-store, max-age=0, must-revalidate"],
          "content-type" => ["application/json; charset=utf-8"],
          "pragma" => ["no-cache"],
          "server" => ["scaffolding on HTTPServer2"]
        },
        "body_type" => "json",
        "body_json" => %{
          "access_token" => "ya29.test_access_token_redacted",
          "expires_in" => 3599,
          "refresh_token" => "1//test_refresh_token_redacted",
          "scope" => "openid email profile https://www.googleapis.com/auth/analytics.edit",
          "token_type" => "Bearer",
          "id_token" => id_token
        }
      }
    }
  end

  defp jwks_interaction(jwk) do
    %{
      "recorded_at" => "2026-04-25T23:00:02Z",
      "request" => %{
        "method" => "GET",
        "uri" => @jwks_uri,
        "query_string" => "",
        "headers" => %{"accept" => ["application/json"]},
        "body_type" => "text",
        "body" => ""
      },
      "response" => %{
        "status" => 200,
        "headers" => %{
          "cache-control" => ["public, max-age=21600"],
          "content-type" => ["application/json; charset=utf-8"],
          "server" => ["scaffolding on HTTPServer2"]
        },
        "body_type" => "json",
        "body_json" => %{"keys" => [jwk]}
      }
    }
  end
end
