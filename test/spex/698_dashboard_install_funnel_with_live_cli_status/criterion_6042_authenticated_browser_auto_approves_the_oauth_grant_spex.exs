defmodule CodeMySpecSpex.Story698.Criterion6042Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6042 — Rule: OAuth approval is silent for the originating
  browser session — when the user is already authenticated to
  codemyspec.com, /codemyspec:authenticate auto-approves the grant
  without showing a consent screen.

  The CLI's `/codemyspec:authenticate` opens a browser tab to the
  OAuth authorize endpoint with PKCE parameters. When the request
  arrives with an authenticated session cookie, the server should
  redirect straight to the CLI's loopback callback with an
  authorization code — never rendering the consent page.

  This spec hits the authorize endpoint with an authenticated conn
  and asserts:
    * the response is a redirect (302/303), not a 200 with a consent body
    * the redirect target is the registered CLI client's redirect_uri
    * the redirect carries a `code` query parameter

  Forward-looking surface: the OAuth provider exposes
  `GET /oauth/authorize` and accepts the standard OAuth2 query params
  (client_id, response_type, redirect_uri, code_challenge,
  code_challenge_method, state). Implementation may use ex_oauth2_provider
  or an Assent-shaped provider; the contract here is endpoint behavior,
  not the underlying library.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  @cli_client_id "codemyspec-cli"
  @cli_redirect_uri "http://localhost:9876/oauth/callback"

  setup :register_log_in_setup_account

  setup do
    _app = Fixtures.cli_oauth_application_fixture()
    :ok
  end

  spex "Authenticated browser auto-approves the OAuth grant" do
    scenario "Authenticated browser auto-approves the OAuth grant" do
      when_ "the authenticated user hits /oauth/authorize with valid CLI params", context do
        params = %{
          "client_id" => @cli_client_id,
          "response_type" => "code",
          "redirect_uri" => @cli_redirect_uri,
          "code_challenge" => "abc123codechallengeplaceholder",
          "code_challenge_method" => "S256",
          "state" => "spex-state"
        }

        conn = get(context.conn, "/oauth/authorize", params)
        {:ok, Map.put(context, :auth_conn, conn)}
      end

      then_ "the response redirects to the CLI callback with an authorization code", context do
        location = redirected_to(context.auth_conn, 302)

        assert String.starts_with?(location, @cli_redirect_uri),
               "expected redirect to #{@cli_redirect_uri}, got: #{location}"

        %URI{query: query} = URI.parse(location)
        params = URI.decode_query(query || "")

        assert Map.has_key?(params, "code"),
               "expected an authorization code in the redirect, got params: #{inspect(params)}"

        assert params["state"] == "spex-state",
               "expected state to round-trip on the redirect"

        {:ok, context}
      end

      then_ "no consent screen body is rendered", context do
        # If a consent screen had rendered, the response would be a 200
        # with a body — not a redirect. redirected_to/2 above would have
        # raised in that case, but assert the negative explicitly so the
        # contract is visible.
        assert context.auth_conn.status in [302, 303],
               "expected a redirect status; a 200 here would mean the consent page rendered"

        body = response(context.auth_conn, context.auth_conn.status) || ""

        refute body =~ ~r/authorize this application/i,
               "did not expect a consent prompt for an already-authenticated user"

        {:ok, context}
      end
    end
  end
end
