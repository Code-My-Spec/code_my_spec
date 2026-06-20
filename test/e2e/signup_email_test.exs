defmodule CodeMySpecWeb.SignupEmailTest do
  @moduledoc """
  End-to-end signup via magic link. Drives the real browser through
  `/users/register` → email submission → magic-link click → `/app` →
  account creation → overview.

  This is the smoke test that would have caught the `Mix.env()` crash
  in `app_live/overview.ex` — it exercises the post-callback `/app`
  render that blew up in compiled releases.
  """

  use CodeMySpecWeb.EndToEndCase, async: false

  @moduletag :e2e

  feature "new user signs up via email magic link, names account, lands on overview", %{
    session: session
  } do
    email = "wallaby-#{System.unique_integer([:positive])}@example.com"
    account_name = "Wallaby Test Co"

    try do
      session
      |> visit("/users/register")
      |> assert_has(css("h2", text: "Get started."))
      |> fill_in(text_field("Email"), with: email)
      |> click(button("Email me a login link"))
      |> assert_has(css("body", text: email))

      captured = TestMailbox.assert_received(email)
      login_url = extract_login_url(captured)

      session
      |> visit(login_url)
      |> assert_has(css("h2", text: "Name your account."))
      |> fill_in(css("input[name='account[name]']"), with: account_name)
      |> click(css("form#account_form button[type='submit']"))
      |> assert_has(css("body", text: account_name))
    rescue
      e ->
        debug_dump(session, "email")
        reraise e, __STACKTRACE__
    end
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

  defp extract_login_url(%Swoosh.Email{text_body: text} = email) when is_binary(text) do
    text
    |> String.split()
    |> Enum.find(&String.contains?(&1, "/users/log-in/")) ||
      raise "no /users/log-in/<token> link found in email: #{inspect(email)}"
  end
end
