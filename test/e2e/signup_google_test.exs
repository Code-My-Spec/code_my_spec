defmodule CodeMySpecWeb.SignupGoogleTest do
  @moduledoc """
  End-to-end signup via real Google OAuth, driven against the local
  test Phoenix endpoint (http://localhost:4002).

  ## Required environment (auto-loaded from envs/dev.env if present)

      GOOGLE_CLIENT_ID      — OAuth 2.0 Client ID. Google clients support
                              multiple Authorized redirect URIs, so the
                              same client that serves dev.codemyspec.com
                              works here too — just add
                              http://localhost:4002/auth/google/callback
                              to its Authorized redirect URIs in Google
                              Cloud Console.
      GOOGLE_CLIENT_SECRET  — corresponding secret
      GOOGLE_TEST_EMAIL     — Google test account email
      GOOGLE_TEST_PASSWORD  — its password

  ## ⚠️ Caveat: Google bot detection

  Google routinely blocks chromedriver-driven logins with "This browser
  may not be secure." If that happens, run once manually in a Chrome
  profile that's logged into the test Google account, then point the
  test at that profile:

      export WALLABY_CHROME_USER_DATA_DIR=/tmp/cms-e2e-chrome-profile

  Test is skipped if any required env var is missing.
  """

  use CodeMySpecWeb.FeatureCase, async: false

  @moduletag :e2e
  @moduletag :e2e_google

  @required_env ~w(GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_TEST_EMAIL GOOGLE_TEST_PASSWORD)

  setup do
    missing = Enum.filter(@required_env, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      {:ok, skip: "missing env: #{Enum.join(missing, ", ")}"}
    else
      original = %{
        client_id: Application.get_env(:code_my_spec, :google_client_id),
        client_secret: Application.get_env(:code_my_spec, :google_client_secret)
      }

      Application.put_env(:code_my_spec, :google_client_id, System.fetch_env!("GOOGLE_CLIENT_ID"))

      Application.put_env(
        :code_my_spec,
        :google_client_secret,
        System.fetch_env!("GOOGLE_CLIENT_SECRET")
      )

      on_exit(fn ->
        Application.put_env(:code_my_spec, :google_client_id, original.client_id)
        Application.put_env(:code_my_spec, :google_client_secret, original.client_secret)
      end)

      :ok
    end
  end

  feature "new Google OAuth user signs up and lands on overview", context do
    if reason = context[:skip] do
      IO.puts("\n[SKIP signup_google] #{reason}")
    else
      run_signup_flow(context.session)
    end
  end

  defp run_signup_flow(session) do
    account_name = "Wallaby Google Co"

    session
    |> visit("/users/register")
    |> click(link("Continue with Google"))
    |> fill_in(css("input[type='email']"), with: System.fetch_env!("GOOGLE_TEST_EMAIL"))
    |> click(css("#identifierNext button"))
    |> fill_in(css("input[type='password']"), with: System.fetch_env!("GOOGLE_TEST_PASSWORD"))
    |> click(css("#passwordNext button"))
    |> maybe_consent()
    |> assert_has(css("h2", text: "Name your account."))
    |> fill_in(css("input[name='account[name]']"), with: account_name)
    |> click(css("form#account_form button[type='submit']"))
    |> assert_has(css("body", text: account_name))
  end

  defp maybe_consent(session) do
    case Wallaby.Browser.find(session, css("button[jsname]"), count: :any) do
      [_ | _] -> Wallaby.Browser.click(session, css("button[jsname]"))
      _ -> session
    end
  rescue
    _ -> session
  end
end
