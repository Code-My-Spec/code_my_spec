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

    email = System.fetch_env!("GOOGLE_TEST_EMAIL")

    session
    |> visit("/users/register")
    |> click(link("Continue with Google"))
    |> pick_or_enter_email(email)
    |> maybe_enter_password(System.fetch_env!("GOOGLE_TEST_PASSWORD"))
    |> maybe_consent()
    |> assert_has(css("h2", text: "Name your account."))
    |> fill_in(css("input[name='account[name]']"), with: account_name)
    |> click(css("form#account_form button[type='submit']"))
    |> assert_has(css("body", text: account_name))
  end

  # The persisted-profile workaround (WALLABY_CHROME_USER_DATA_DIR)
  # keeps Google's account-chooser cookies, so the first page after
  # "Continue with Google" can be EITHER the identifier (email) page
  # OR the account chooser. Branch on what's actually rendered.
  # After "Continue with Google", the next page can be any of:
  #   - account chooser (returning user, multiple accounts cached)
  #   - identifier (email) page (fresh session)
  #   - OAuth identity confirmation (already auth'd for this app via
  #     persisted profile — skip straight to consent)
  # Try each in turn; if none match we're already past the email step.
  defp pick_or_enter_email(session, email) do
    :timer.sleep(1_500)

    try_chooser(session, email) ||
      try_email_form(session, email) ||
      session
  end

  defp try_chooser(session, email) do
    Wallaby.Browser.click(session, css(~s([data-identifier="#{email}"])))
  rescue
    _ -> nil
  end

  defp try_email_form(session, email) do
    session
    |> fill_in(css("input[type='email']"), with: email)
    |> click(css("#identifierNext"))
  rescue
    _ -> nil
  end

  # If the persisted profile already has a fresh Google session, Google
  # skips the password page entirely and goes straight to OAuth
  # confirmation. Only enter the password if the field is actually there.
  defp maybe_enter_password(session, password) do
    :timer.sleep(2_000)

    session
    |> fill_in(css("input[type='password']"), with: password)
    |> click(css("#passwordNext"))
  rescue
    _ -> session
  end

  # OAuth consent / account-confirmation pages render a "Continue"
  # primary button. Wait briefly for it; if it doesn't appear (already
  # auto-confirmed and redirected to our callback), skip.
  defp maybe_consent(session) do
    :timer.sleep(2_000)

    session |> click(Wallaby.Query.button("Continue"))
  rescue
    _ -> session
  end
end
