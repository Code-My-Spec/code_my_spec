defmodule CodeMySpecWeb.SignupGithubTest do
  @moduledoc """
  End-to-end signup via real GitHub OAuth, driven against the local
  test Phoenix endpoint (http://localhost:4002).

  ## Required environment (auto-loaded from envs/dev.env if present)

      GITHUB_CLIENT_ID      — OAuth App client_id whose authorization
                              callback URL is
                              http://localhost:4002/auth/github/callback.
                              (Set in envs/test.env — distinct from the
                              dev.codemyspec.com client of the same name
                              in envs/dev.env.)
      GITHUB_CLIENT_SECRET  — corresponding secret
      GITHUB_TEST_EMAIL     — login email for a throwaway GitHub account
      GITHUB_TEST_PASSWORD  — its password

  ## GitHub OAuth app config

  GitHub OAuth Apps allow multiple authorization callback URLs. Add
  `http://localhost:4002/auth/github/callback` to the app whose
  client_id is in GITHUB_CLIENT_ID. Without that, the callback redirect
  will 404 and the test will fail at the `assert_has` on /app.

  ## Anti-bot one-time setup

  The FIRST time you authorize this OAuth app for the test account,
  GitHub presents a consent page with a button that's disabled until
  it sees mouse movement. The test handles this with a mouse-nudge,
  but if it flakes, complete the authorization once manually in any
  browser logged in as the test account.

  Test is skipped if any required env var is missing.
  """

  use CodeMySpecWeb.FeatureCase, async: false

  @moduletag :e2e
  @moduletag :e2e_github

  @required_env ~w(GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET GITHUB_TEST_EMAIL GITHUB_TEST_PASSWORD)

  setup do
    missing = Enum.filter(@required_env, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      {:ok, skip: "missing env: #{Enum.join(missing, ", ")}"}
    else
      original = %{
        client_id: Application.fetch_env!(:code_my_spec, :github_client_id),
        client_secret: Application.fetch_env!(:code_my_spec, :github_client_secret)
      }

      Application.put_env(:code_my_spec, :github_client_id, System.fetch_env!("GITHUB_CLIENT_ID"))

      Application.put_env(
        :code_my_spec,
        :github_client_secret,
        System.fetch_env!("GITHUB_CLIENT_SECRET")
      )

      on_exit(fn ->
        Application.put_env(:code_my_spec, :github_client_id, original.client_id)
        Application.put_env(:code_my_spec, :github_client_secret, original.client_secret)
      end)

      :ok
    end
  end

  feature "new GitHub OAuth user signs up and lands on overview", context do
    if reason = context[:skip] do
      IO.puts("\n[SKIP signup_github] #{reason}")
    else
      run_signup_flow(context.session)
    end
  end

  defp run_signup_flow(session) do
    account_name = "Wallaby GitHub Co"

    try do
      session
      |> visit("/users/register")
      |> click(link("Continue with GitHub"))
      |> fill_in(css("#login_field"), with: System.fetch_env!("GITHUB_TEST_EMAIL"))
      |> fill_in(css("#password"), with: System.fetch_env!("GITHUB_TEST_PASSWORD"))
      |> click(css("input[type='submit'][name='commit']"))
      |> maybe_authorize()
      |> assert_has(css("h2", text: "Name your account."))
      |> fill_in(css("input[name='account[name]']"), with: account_name)
      |> click(css("form#account_form button[type='submit']"))
      |> assert_has(css("body", text: account_name))
    rescue
      e ->
        debug_dump(session, "github")
        reraise e, __STACKTRACE__
    end
  end

  defp maybe_authorize(session) do
    # GitHub's authorize page only appears on the FIRST OAuth flow for a
    # given (user, app) pair. After that GitHub redirects straight to
    # the callback. Detect by URL.
    if String.contains?(Wallaby.Browser.current_url(session), "/login/oauth/authorize") do
      session
      |> nudge_mouse()
      |> Wallaby.Browser.click(css("button.js-oauth-authorize-btn"))
    else
      session
    end
  end

  defp nudge_mouse(session) do
    # GitHub disables the authorize button until it sees real mouse
    # movement. Chromedriver's move_mouse_by dispatches trusted moves;
    # several spaced moves satisfy the heuristic.
    Enum.reduce(
      [{50, 80}, {-30, 60}, {120, -40}, {-70, 25}, {40, -50}, {-15, 35}],
      session,
      fn {dx, dy}, sess ->
        Process.sleep(80)
        Wallaby.Browser.move_mouse_by(sess, dx, dy)
      end
    )
  end

  defp debug_dump(session, label) do
    ts = System.system_time(:second)
    png = "/tmp/wallaby-#{label}-failure-#{ts}.png"
    html_path = "/tmp/wallaby-#{label}-failure-#{ts}.html"
    Wallaby.Browser.take_screenshot(session, name: png)
    File.write!(html_path, Wallaby.Browser.page_source(session))
    IO.puts("\n[wallaby debug] current_url=#{Wallaby.Browser.current_url(session)}")
    IO.puts("[wallaby debug] screenshot=#{png}")
    IO.puts("[wallaby debug] html=#{html_path}")
  end
end
