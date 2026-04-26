defmodule CodeMySpecSpex.Story602.Criterion5369Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5369 — Integration save failure still leaves the user logged in
  with user and personal account.

  The controller calls Integrations.save_integration/4 but does not check its
  return value — it fires and forgets. If save_integration fails (e.g., because
  the token response omits the required access_token field and the changeset
  validation rejects it), the user should still be logged in with a session
  token, and their personal account should still exist.

  We induce the failure through the surface layer by replaying a Google OIDC
  cassette whose token response omits the `access_token` field. This causes
  `persist_integration` to build a changeset with `access_token: nil`, which
  fails the `:required` validation. The controller ignores the `{:error,
  changeset}` return value and calls `UserAuth.log_in_user/3` regardless.

  NOTE: This spec will FAIL until the current controller code is correct — the
  fix under test is that `save_integration`'s return value is ignored (already
  the case today) AND that `ensure_personal_account` is called before the
  save attempt (the production fix being tracked by story 602).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  @cassette_dir "test/cassettes/oauth"
  @issuer "https://accounts.google.com"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @jwks_uri "https://www.googleapis.com/oauth2/v3/certs"
  @authorization_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @kid "test-google-key-broken-token"


  spex "Integration save failure still leaves the user logged in with user and personal account" do
    scenario "Google callback with missing access_token: user is logged in, account exists, integration is absent" do
      given_ "the Google token response omits access_token (simulating a save-failure path)",
             context do
        unique = System.unique_integer([:positive])

        user_claims = %{
          "sub" => "google-sub-5369-#{unique}",
          "email" => "google-5369-#{unique}@example.com",
          "email_verified" => true,
          "name" => "Save Failure Test User"
        }

        cassette_name = "google_5369_no_token_#{unique}"
        build_broken_google_cassette!(cassette_name, user_claims)

        {:ok,
         Map.merge(context, %{
           user_claims: user_claims,
           cassette_name: cassette_name
         })}
      end

      when_ "the Google OAuth callback fires", context do
        conn =
          with_cassette context.cassette_name, cassette_opts(), fn plug ->
            with_assent_plug(plug, fn ->
              build_conn()
              |> Phoenix.ConnTest.init_test_session(%{})
              |> Plug.Conn.put_session(:oauth_provider, :google)
              |> Plug.Conn.put_session(:oauth_session_params, %{state: "state-5369"})
              |> Plug.Conn.put_session(:oauth_flow, :login)
              |> get("/auth/google/callback", %{
                "code" => "google-replay-code",
                "state" => "state-5369"
              })
            end)
          end

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the user is still logged in despite the integration save failure", context do
        user_token = Plug.Conn.get_session(context.conn, :user_token)

        assert user_token != nil,
               "expected a session token even when integration save fails — " <>
                 "the controller must not gate login on save_integration success"

        {:ok, _view, html} =
          context.conn
          |> recycle()
          |> live("/app/users/settings")

        assert html =~ context.user_claims["email"],
               "expected /app/users/settings to render the OAuth user's email " <>
                 "even though the integration save failed"

        :ok
      end

      then_ "the user has a personal account despite the integration save failure", context do
        # The picker lists every account the user owns. A "Personal" badge
        # confirms ensure_personal_account/1 ran before the failed
        # save_integration call.
        local_part = context.user_claims["email"] |> String.split("@") |> List.first()

        {:ok, _view, html} =
          context.conn
          |> recycle()
          |> live("/app/accounts/picker")

        assert html =~ "Personal",
               "expected a Personal badge on the picker — ensure_personal_account " <>
                 "must run before save_integration so a save failure can't strand the user"

        assert html =~ local_part,
               "expected the personal account named after the email local-part " <>
                 "(#{local_part}) to be listed on the picker"

        :ok
      end
    end
  end

  # -- Helpers --


  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :replay,
      match_requests_on: [:method, :uri],
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

  # Builds a Google OIDC cassette whose token endpoint response deliberately
  # omits `access_token`. This causes `persist_integration` to receive
  # `access_token: nil`, which fails the Integration changeset's required
  # validation. The controller must still log the user in.
  defp build_broken_google_cassette!(cassette_name, user_claims) do
    {pem, n, e} = generate_rsa_keypair()
    client_id = Application.fetch_env!(:code_my_spec, :google_client_id)
    id_token = sign_id_token(pem, user_claims, client_id)
    jwk = public_jwk(n, e)

    # Token response with empty-string access_token — Assent accepts it as
    # present, but Ecto's `cast` normalizes "" to nil for the required field,
    # so the Integration changeset fails validation and the upsert returns
    # `{:error, changeset}`. The controller fires-and-forgets the result, so
    # the user is still logged in despite the save failure.
    broken_token_response = %{
      "access_token" => "",
      "expires_in" => 3599,
      "token_type" => "Bearer",
      "id_token" => id_token
    }

    cassette = %{
      "version" => "2.0",
      "interactions" => [
        openid_configuration_interaction(),
        token_interaction(broken_token_response),
        jwks_interaction(jwk)
      ]
    }

    File.mkdir_p!(@cassette_dir)
    path = Path.join(@cassette_dir, cassette_name <> ".json")
    File.write!(path, Jason.encode!(cassette, pretty: true))
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    :ok
  end

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

  defp token_interaction(token_response) do
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
        "body_json" => token_response
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
end
