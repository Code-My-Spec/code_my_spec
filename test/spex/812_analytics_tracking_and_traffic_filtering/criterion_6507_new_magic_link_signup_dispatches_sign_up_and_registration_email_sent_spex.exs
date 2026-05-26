defmodule CodeMySpecSpex.Story812.Criterion6507Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6507 — Rule 3: New magic-link signup dispatches `:sign_up`
  (method "magic_link") and `:registration_email_sent`.

  Test-subscriber pattern: `Fixtures.attach_ga_test_subscriber/1` registers
  this test process to receive every GA Measurement Protocol payload as
  `{:ga_measurement_protocol, payload}`. We drive the real registration
  LiveView, then assert both MP payloads arrive in the test mailbox.

  No cassette, no real GA round-trip — the subscriber short-circuits
  `deliver/2` before any HTTP call is made.
  """

  use CodeMySpecSpex.Case

  # /users/register lives on the main web router, not LocalWeb.
  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "New magic-link signup dispatches :sign_up and :registration_email_sent" do
    scenario "registering a fresh email fires sign_up (method magic_link) then registration_email_sent" do
      given_ "no existing user row for the test email", context do
        email = "spex-812-#{System.unique_integer([:positive])}@codemyspec.test"
        {:ok, Map.put(context, :email, email)}
      end

      when_ "the visitor submits the magic-link registration form", context do
        {:ok, lv, _html} = live(context.conn, "/users/register")

        # push_navigate on success returns {:error, {:live_redirect, ...}} —
        # that is the happy path here, not a failure.
        lv
        |> form("#registration_form", user: %{email: context.email})
        |> render_submit()

        {:ok, context}
      end

      then_ "a sign_up MP payload arrives with method=magic_link", context do
        assert_receive {:ga_measurement_protocol,
                        %{events: [%{name: "sign_up", params: params} | _]}},
                       1_000

        assert params["method"] == "magic_link",
               "Expected sign_up MP event params to carry method=\"magic_link\", got: #{inspect(params["method"])}"

        {:ok, context}
      end

      then_ "a registration_email_sent MP payload also arrives", context do
        assert_receive {:ga_measurement_protocol,
                        %{events: [%{name: "registration_email_sent"} | _]}},
                       1_000

        {:ok, context}
      end
    end
  end
end
