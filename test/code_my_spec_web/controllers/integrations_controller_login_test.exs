defmodule CodeMySpecWeb.IntegrationsControllerLoginTest do
  @moduledoc """
  Tests the GitHub OAuth social-login flow end-to-end through
  `IntegrationsController.callback/2`, using ReqCassette to record and replay
  the live HTTP exchange with GitHub.

  ## Recording the cassette

  Recording requires real GitHub OAuth credentials and a single-use `code` from
  a fresh GitHub authorization. GitHub codes expire in ~10 minutes, so move
  fast.

  1. Configure a GitHub OAuth App with callback URL
     `http://127.0.0.1:4002/auth/github/callback` (the Phoenix test endpoint).

  2. Build the authorize URL by hand and open it in a browser:

         https://github.com/login/oauth/authorize?
           client_id=YOUR_REAL_CLIENT_ID
           &redirect_uri=http%3A%2F%2F127.0.0.1%3A4002%2Fauth%2Fgithub%2Fcallback
           &scope=user%3Aemail
           &state=record_state

  3. Complete the GitHub consent screen. GitHub will redirect to
     `http://127.0.0.1:4002/auth/github/callback?code=XXX&state=record_state`.
     The browser will fail to load (test endpoint is not running) — that's
     fine. Copy `code` and `state` out of the URL bar **immediately**.

  4. Delete any stale cassette so a fresh recording is captured:

         rm -f test/cassettes/oauth/github_login_new_user.json

  5. Run the test in record mode with real creds + the fresh code:

         GITHUB_CLIENT_ID=real_id \\
         GITHUB_CLIENT_SECRET=real_secret \\
         GITHUB_OAUTH_CODE=XXX \\
         GITHUB_OAUTH_STATE=record_state \\
         RECORD_GITHUB_OAUTH=1 \\
         mix test test/code_my_spec_web/controllers/integrations_controller_login_test.exs

  Subsequent runs (without env vars) replay from the cassette. The cassette
  filters `authorization` headers and `client_secret` / `access_token` from
  request/response bodies, but inspect it before committing.
  """

  use CodeMySpecTest.ConnCase, async: false

  import ReqCassette

  alias CodeMySpec.Accounts
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope

  @cassette_dir "test/cassettes/oauth"
  @cassette_name "github_login_new_user"

  describe "GET /auth/github/callback (login flow) — new user" do
    @describetag :capture_log

    test "creates a personal account so the user can pick one in Workspace",
         %{conn: conn} do
      with_cassette @cassette_name, cassette_opts(), fn plug ->
        with_assent_plug(plug, fn ->
          {code, state} = oauth_callback_params()

          conn =
            conn
            |> Phoenix.ConnTest.init_test_session(%{})
            |> Plug.Conn.put_session(:oauth_provider, :github)
            |> Plug.Conn.put_session(:oauth_session_params, %{state: state})
            |> Plug.Conn.put_session(:oauth_flow, :login)

          conn = get(conn, ~p"/auth/github/callback", %{"code" => code, "state" => state})

          assert redirected_to(conn) in [~p"/app/onboarding", ~p"/app", ~p"/"]
          assert user_token = Plug.Conn.get_session(conn, :user_token)
          assert {user, _inserted_at} = Users.get_user_by_session_token(user_token)

          # The bug: GitHub OAuth login never calls Accounts.ensure_personal_account/1
          # (only the magic-link confirmation flow does, in
          # CodeMySpecWeb.UserLive.Confirmation.handle_event/3). Without an
          # account, Workspace > Projects shows "Select Account" with nothing
          # to select.
          assert Accounts.get_personal_account(Scope.for_user(user)),
                 "expected a personal account to be created for a new GitHub user"
        end)
      end
    end
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: cassette_mode(),
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        {~r/client_secret=[^&\s"]+/, "client_secret=<REDACTED>"},
        {~r/"access_token"\s*:\s*"[^"]+"/, ~s("access_token":"<REDACTED>")},
        {~r/access_token=[^&\s"]+/, "access_token=<REDACTED>"},
        {~r/"refresh_token"\s*:\s*"[^"]+"/, ~s("refresh_token":"<REDACTED>")}
      ]
    ]
  end

  defp cassette_mode do
    if System.get_env("RECORD_GITHUB_OAUTH") == "1", do: :record, else: :replay
  end

  defp oauth_callback_params do
    case cassette_mode() do
      :record ->
        code =
          System.get_env("GITHUB_OAUTH_CODE") ||
            flunk("RECORD_GITHUB_OAUTH=1 requires GITHUB_OAUTH_CODE — see @moduledoc")

        state =
          System.get_env("GITHUB_OAUTH_STATE") ||
            flunk("RECORD_GITHUB_OAUTH=1 requires GITHUB_OAUTH_STATE — see @moduledoc")

        # Real creds are required to actually exchange the code with GitHub.
        if client_id = System.get_env("GITHUB_CLIENT_ID") do
          Application.put_env(:code_my_spec, :github_client_id, client_id)
        end

        if client_secret = System.get_env("GITHUB_CLIENT_SECRET") do
          Application.put_env(:code_my_spec, :github_client_secret, client_secret)
        end

        {code, state}

      :replay ->
        # The cassette matches on method + uri only, so the code/state values
        # used here don't have to match the recorded ones — they only need to
        # be consistent with each other so OAuth state validation passes.
        {"replay-code", "replay-state"}
    end
  end

  # Assent's HTTPAdapter is the seam where ReqCassette's Plug gets injected.
  # Setting it via Application env (rather than per-request config) avoids
  # threading the plug through CodeMySpec.Integrations and the GitHub provider.
  # `async: false` on the module guards the global mutation.
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
