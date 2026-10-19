defmodule CodeMySpecDesktop.SetupPageTest do
  use ExUnit.Case, async: true

  alias CodeMySpecDesktop.Application.SetupPage

  test "pending authorization displays escaped approval details and refreshes" do
    status = %{
      phase: :ready,
      authorization: %{
        phase: :pending,
        verification_uri: "https://example.test/oauth/device?a=1&b=2",
        user_code: "<ABC>",
        device_code: "private-device-code"
      }
    }

    html = SetupPage.render(status, "/setup/launch", "/app")
    assert html =~ "https://example.test/oauth/device?a=1&amp;b=2"
    assert html =~ "&lt;ABC&gt;"
    assert html =~ "http-equiv=\"refresh\""
    refute html =~ "private-device-code"
    refute html =~ "<ABC>"
  end

  test "stopped authorization offers an explicit retry without refreshing" do
    html =
      SetupPage.render(
        %{phase: :ready, authorization: %{phase: :stopped}},
        "/setup/launch",
        "/app"
      )

    assert html =~ "action=\"/setup/launch/authorize\""
    assert html =~ "retry-authorization"
    refute html =~ "http-equiv=\"refresh\""
  end

  test "authorized harness shows success and stops refreshing" do
    html =
      SetupPage.render(
        %{phase: :ready, authorization: %{phase: :authorized}},
        "/setup/launch",
        "/app"
      )

    assert html =~ "This harness is connected."
    assert html =~ "Continue to CodeMySpec"
    refute html =~ "authorization-code"
    refute html =~ "http-equiv=\"refresh\""
  end
end
