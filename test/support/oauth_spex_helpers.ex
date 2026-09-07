defmodule CodeMySpecSpex.OAuthHelpers do
  @moduledoc """
  Shared helpers for Story 602 BDD specs that exercise the OAuth callback surface.

  Provides:
  - `build_google_cassette!/2` — loads `test/cassettes/oauth/google_login_shape.json`
    (a real Google OIDC recording with id_token + JWKS keys scrubbed to
    placeholders) and injects a fresh per-test id_token + matching JWK.
    Catches drift on Google's response shape forever (everything except
    the cryptographic material is real Google data) without binding tests
    to time-bound real id_tokens.
    Failure-path scenarios pass `:token_response_overrides` opts to merge
    arbitrary fields into the token endpoint response (criterion 5369 sets
    `access_token: ""` to drive a save-failure code path).
  - `build_github_cassette!/3` — loads `test/cassettes/oauth/github_login_shape.json`
    (a real recording of GitHub's /user and /user/emails responses, with PII
    scrubbed to placeholders) and replaces the response bodies with the
    supplied per-test user_json + emails_json. The token-exchange
    interaction in the shape file is synthetic — we can't record it for
    real without a fresh OAuth auth_code, and its response shape is trivial.
  - `with_assent_plug/2` — injects ReqCassette's plug into the Assent HTTP
    adapter for the duration of a single call block.
  - `do_google_callback/3` / `do_github_callback/3` — drive the full
    `GET /auth/<provider>/callback` request with the correct session flags
    and return the resulting conn.

  ## Re-recording the shape cassettes

  See `record_google_login_shape` and `record_github_login_shape` tests in
  `test/code_my_spec/integrations_test.exs`:

      # Google
      rm test/cassettes/oauth/google_login_shape.json
      TEST_GOOGLE_REFRESH_TOKEN=<rt> mix test --only record_google_login_shape

      # GitHub
      rm test/cassettes/oauth/github_login_shape.json
      TEST_GITHUB_ACCESS_TOKEN=<at> mix test --only record_github_login_shape

  Tokens come from the dev DB integrations table — the existing rows for
  your user have valid access_tokens; the Google one needs a refresh_token
  which is only persisted via the integration flow at `/app/users/settings`
  (login flow strips `prompt=consent`).
  """

  use Boundary, deps: []

  import Phoenix.ConnTest
  import Plug.Conn
  import ReqCassette

  alias Assent.JWTAdapter.AssentJWT

  @cassette_dir "test/cassettes/oauth"
  @endpoint CodeMySpecWeb.Endpoint

  @issuer "https://accounts.google.com"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @jwks_uri "https://www.googleapis.com/oauth2/v3/certs"
  @kid "test-google-key-1"

  @shape_cassette_path "test/cassettes/oauth/google_login_shape.json"

  @doc """
  Builds a Google OIDC cassette by loading the real-shape recording at
  `test/cassettes/oauth/google_login_shape.json` and injecting a fresh
  per-test id_token + matching JWK so signature verification passes.

  The recording was captured against real Google (see the
  `record_google_login_shape` test in `integrations_test.exs`); the id_token
  and JWKS keys were scrubbed to placeholders that this helper fills in
  with values bound to a fresh RSA keypair generated per test. That gives
  us drift detection on Google's response shape (everything else in the
  cassette is real Google data) without binding tests to time-bound real
  id_tokens.

  ## Options

  - `:token_response_overrides` — map merged into the token endpoint
    response body before write. Used by criterion 5369 to inject a broken
    (`access_token: ""`) response without abandoning the real-shape
    recording. Don't override `id_token` — that gets re-injected after
    the merge with a freshly-signed JWT.
  """
  def build_google_cassette!(cassette_name, user_claims, opts \\ []) do
    overrides = Keyword.get(opts, :token_response_overrides, %{})
    {pem, n, e} = generate_rsa_keypair()
    client_id = Application.fetch_env!(:code_my_spec, :google_client_id)
    id_token = sign_id_token(pem, user_claims, client_id)
    jwk = public_jwk(n, e)

    shape =
      @shape_cassette_path
      |> File.read!()
      |> Jason.decode!()

    cassette =
      shape
      |> merge_token_response(overrides)
      |> inject_id_token(id_token)
      |> inject_jwks([jwk])

    File.mkdir_p!(@cassette_dir)
    path = Path.join(@cassette_dir, cassette_name <> ".json")
    File.write!(path, Jason.encode!(cassette, pretty: true))
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp merge_token_response(cassette, overrides) when overrides == %{}, do: cassette

  defp merge_token_response(cassette, overrides) do
    update_in(cassette, ["interactions"], fn interactions ->
      Enum.map(interactions, fn interaction ->
        if get_in(interaction, ["request", "uri"]) == @token_endpoint do
          update_in(interaction, ["response", "body_json"], &Map.merge(&1, overrides))
        else
          interaction
        end
      end)
    end)
  end

  defp inject_id_token(cassette, id_token) do
    update_in(cassette, ["interactions"], fn interactions ->
      Enum.map(interactions, fn interaction ->
        if get_in(interaction, ["request", "uri"]) == @token_endpoint do
          put_in(interaction, ["response", "body_json", "id_token"], id_token)
        else
          interaction
        end
      end)
    end)
  end

  defp inject_jwks(cassette, jwks) do
    update_in(cassette, ["interactions"], fn interactions ->
      Enum.map(interactions, fn interaction ->
        if get_in(interaction, ["request", "uri"]) == @jwks_uri do
          put_in(interaction, ["response", "body_json", "keys"], jwks)
        else
          interaction
        end
      end)
    end)
  end

  @github_shape_cassette_path "test/cassettes/oauth/github_login_shape.json"
  @github_user_url "https://api.github.com/user"
  @github_user_emails_url "https://api.github.com/user/emails"

  @doc """
  Builds a GitHub OAuth cassette by loading the real-shape recording at
  `test/cassettes/oauth/github_login_shape.json` and replacing the /user
  and /user/emails response bodies with `user_json` and `emails_json`.

  The recording captured a real GitHub /user object (with PII scrubbed to
  placeholders); injecting per-test bodies preserves the real response
  shape (HTTP status, headers, response wrapper) while letting each scenario
  exercise its own user/email data. The token-exchange interaction in the
  shape file is synthetic — its response shape is trivial and we can't
  record it for real without a fresh OAuth auth_code.
  """
  def build_github_cassette!(cassette_name, user_json, emails_json) do
    shape =
      @github_shape_cassette_path
      |> File.read!()
      |> Jason.decode!()

    cassette =
      shape
      |> inject_response_body(@github_user_url, user_json)
      |> inject_response_body(@github_user_emails_url, emails_json)

    File.mkdir_p!(@cassette_dir)
    path = Path.join(@cassette_dir, cassette_name <> ".json")
    File.write!(path, Jason.encode!(cassette, pretty: true))
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp inject_response_body(cassette, target_uri, body) do
    update_in(cassette, ["interactions"], fn interactions ->
      Enum.map(interactions, fn interaction ->
        if get_in(interaction, ["request", "uri"]) == target_uri do
          put_in(interaction, ["response", "body_json"], body)
        else
          interaction
        end
      end)
    end)
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
      AssentJWT.sign(
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

end
