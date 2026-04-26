defmodule CodeMySpecSpex.OAuthHelpers do
  @moduledoc """
  Shared helpers for Story 602 BDD specs that exercise the OAuth callback surface.

  Provides:
  - `build_google_cassette!/2` — generates a fresh RSA keypair, signs a JWT,
    and writes a ReqCassette-format JSON cassette for a single Google OIDC flow.
  - `build_github_cassette!/3` — writes a GitHub OAuth cassette with supplied
    user data and email list.
  - `with_assent_plug/2` — injects ReqCassette's plug into the Assent HTTP
    adapter for the duration of a single call block.
  - `do_google_callback/3` — drives the full GET /auth/google/callback request
    with the correct session flags and returns the resulting conn.
  - `do_github_callback/3` — drives the full GET /auth/github/callback request
    and returns the resulting conn.

  These helpers isolate the OAuth cassette machinery so that each of the 10
  story-602 spec files stays focused on its single scenario rather than
  repeating RSA/JWT/cassette setup.
  """

  import Phoenix.ConnTest
  import Plug.Conn
  import ReqCassette

  @cassette_dir "test/cassettes/oauth"
  @endpoint CodeMySpecWeb.Endpoint

  @issuer "https://accounts.google.com"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @jwks_uri "https://www.googleapis.com/oauth2/v3/certs"
  @authorization_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @kid "test-google-key-1"

  @doc """
  Builds a Google OIDC cassette from a fresh RSA keypair and writes it to
  `test/cassettes/oauth/<cassette_name>.json`. Registers an `on_exit` to
  clean up the file. Returns `:ok`.
  """
  def build_google_cassette!(cassette_name, user_claims) do
    build_google_cassette_with_token!(cassette_name, user_claims, fn id_token ->
      %{
        "access_token" => "ya29.test_access_token",
        "expires_in" => 3599,
        "token_type" => "Bearer",
        "id_token" => id_token
      }
    end)
  end

  @doc """
  Variant of `build_google_cassette!/2` that lets the caller shape the token
  endpoint response. Used by criterion 5369 to inject a broken
  (`access_token: ""`) response and verify the controller still logs the
  user in.
  """
  def build_google_cassette_with_token!(cassette_name, user_claims, token_response_fn)
      when is_function(token_response_fn, 1) do
    {pem, n, e} = generate_rsa_keypair()
    client_id = Application.fetch_env!(:code_my_spec, :google_client_id)
    id_token = sign_id_token(pem, user_claims, client_id)
    jwk = public_jwk(n, e)

    cassette = %{
      "version" => "2.0",
      "interactions" => [
        openid_configuration_interaction(),
        token_interaction_with_response(token_response_fn.(id_token)),
        jwks_interaction(jwk)
      ]
    }

    File.mkdir_p!(@cassette_dir)
    path = Path.join(@cassette_dir, cassette_name <> ".json")
    File.write!(path, Jason.encode!(cassette, pretty: true))
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    :ok
  end

  @doc """
  Builds a GitHub OAuth cassette. `user_json` is the map returned from
  GET /user (must include "id", "login", etc.). `emails_json` is the list
  returned from GET /user/emails. Uses fixed replay values for code/state.
  """
  def build_github_cassette!(cassette_name, user_json, emails_json) do
    cassette = %{
      "version" => "2.0",
      "interactions" => [
        github_token_interaction(),
        github_user_interaction(user_json),
        github_emails_interaction(emails_json)
      ]
    }

    File.mkdir_p!(@cassette_dir)
    path = Path.join(@cassette_dir, cassette_name <> ".json")
    File.write!(path, Jason.encode!(cassette, pretty: true))
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    :ok
  end

  @doc """
  Temporarily replaces the Assent HTTP adapter with the given ReqCassette plug
  for the duration of `fun/0`.
  """
  def with_assent_plug(plug, fun) do
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

  @doc """
  Drives the Google OAuth callback through `GET /auth/google/callback` using
  the named cassette. Returns the resulting conn.
  """
  def do_google_callback(base_conn, cassette_name, state \\ "google-state") do
    with_cassette cassette_name, cassette_opts(), fn plug ->
      with_assent_plug(plug, fn ->
        base_conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_session(:oauth_provider, :google)
        |> put_session(:oauth_session_params, %{state: state})
        |> put_session(:oauth_flow, :login)
        |> get("/auth/google/callback", %{"code" => "google-replay-code", "state" => state})
      end)
    end
  end

  @doc """
  Drives the GitHub OAuth callback through `GET /auth/github/callback` using
  the named cassette. Returns the resulting conn.
  """
  def do_github_callback(base_conn, cassette_name, state \\ "replay-state") do
    with_cassette cassette_name, cassette_opts(), fn plug ->
      with_assent_plug(plug, fn ->
        base_conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_session(:oauth_provider, :github)
        |> put_session(:oauth_session_params, %{state: state})
        |> put_session(:oauth_flow, :login)
        |> get("/auth/github/callback", %{"code" => "replay-code", "state" => state})
      end)
    end
  end

  @doc """
  Returns cassette options for replay mode.
  """
  def cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :replay,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"]
    ]
  end

  # -- Private: RSA / JWT / cassette generation --

  defp generate_rsa_keypair do
    rsa_private = :public_key.generate_key({:rsa, 2048, 65_537})
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
        "headers" => %{"content-type" => ["application/json; charset=utf-8"]},
        "body_type" => "json",
        "body_json" => %{
          "issuer" => @issuer,
          "authorization_endpoint" => @authorization_endpoint,
          "token_endpoint" => @token_endpoint,
          "jwks_uri" => @jwks_uri,
          "response_types_supported" => ["code"],
          "subject_types_supported" => ["public"],
          "id_token_signing_alg_values_supported" => ["RS256"],
          "scopes_supported" => ["openid", "email", "profile"],
          "token_endpoint_auth_methods_supported" => ["client_secret_post"],
          "claims_supported" => ["aud", "email", "email_verified", "exp", "iat", "iss", "sub"],
          "code_challenge_methods_supported" => ["S256"],
          "grant_types_supported" => ["authorization_code"]
        }
      }
    }
  end

  defp token_interaction_with_response(body_json) do
    %{
      "recorded_at" => "2026-04-25T23:00:01Z",
      "request" => %{
        "method" => "POST",
        "uri" => @token_endpoint,
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
        "headers" => %{"content-type" => ["application/json; charset=utf-8"]},
        "body_type" => "json",
        "body_json" => %{"keys" => [jwk]}
      }
    }
  end

  defp github_token_interaction do
    %{
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
        "headers" => %{
          "content-type" => ["application/x-www-form-urlencoded; charset=utf-8"]
        },
        "body_type" => "text",
        "body" => "access_token=test_github_token&scope=user%3Aemail&token_type=bearer"
      }
    }
  end

  defp github_user_interaction(user_json) do
    %{
      "recorded_at" => "2026-04-25T23:00:01Z",
      "request" => %{
        "method" => "GET",
        "uri" => "https://api.github.com/user",
        "query_string" => "",
        "headers" => %{"accept" => ["application/json"]},
        "body_type" => "text",
        "body" => ""
      },
      "response" => %{
        "status" => 200,
        "headers" => %{"content-type" => ["application/json; charset=utf-8"]},
        "body_type" => "json",
        "body_json" => user_json
      }
    }
  end

  defp github_emails_interaction(emails_json) do
    %{
      "recorded_at" => "2026-04-25T23:00:02Z",
      "request" => %{
        "method" => "GET",
        "uri" => "https://api.github.com/user/emails",
        "query_string" => "",
        "headers" => %{"accept" => ["application/json"]},
        "body_type" => "text",
        "body" => ""
      },
      "response" => %{
        "status" => 200,
        "headers" => %{"content-type" => ["application/json; charset=utf-8"]},
        "body_type" => "json",
        "body_json" => emails_json
      }
    }
  end
end
