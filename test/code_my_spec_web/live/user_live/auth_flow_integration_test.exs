defmodule CodeMySpecWeb.UserLive.AuthFlowIntegrationTest do
  @moduledoc """
  Coverage for the parts of the signup flow that the story-601 spex
  don't already cover.

  Story 601 spex (`test/spex/601_*`) drive register → magic-link
  click → provisioning → /app. This file picks up the
  one bit not in scope of that story: the **resend button** on
  `/users/check-email`. The requirements doc held the
  check-email/resend logic out of scope of 601, so it needs its
  own guardrail somewhere.

  We deliberately stop at "the button issues a fresh, well-formed
  magic-link email." Whether that link then authenticates is
  spex 5353's job — duplicating it here would be churn the next
  time auth changes shape.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  @magic_link_url_regex ~r|https?://[^\s]+/users/log-in/[A-Za-z0-9_\-]+|

  describe "check-email resend button" do
    test "resending issues a fresh magic-link email", %{conn: conn} do
      email = unique_user_email()

      {:ok, register_lv, _} = live(conn, ~p"/users/register")

      {:ok, check_lv, _} =
        register_lv
        |> form("#registration_form", user: valid_user_attributes(email: email))
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/check-email?email=#{email}")

      # Drain the registration email so the next assert_receive only
      # sees the resent one.
      assert_receive {:email, %Swoosh.Email{}}, 500

      check_lv |> element("#resend-button") |> render_click()

      assert_receive {:email, %Swoosh.Email{} = resent}, 500
      assert {_, ^email} = hd(resent.to)
      assert Regex.match?(@magic_link_url_regex, resent.text_body)
    end
  end
end
