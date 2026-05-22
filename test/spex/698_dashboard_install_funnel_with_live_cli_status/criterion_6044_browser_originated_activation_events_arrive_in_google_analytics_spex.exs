defmodule CodeMySpecSpex.Story698.Criterion6044Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6044 — Rule: Activation events reach Google Analytics,
  including activation events triggered by browser activity.

  The events covered here (`onboarding_panel_viewed`, `install_step_copied`)
  are still browser-initiated — the LiveView sees the mount or copy click
  — but server-side delivery to GA goes through the Measurement Protocol,
  not through `gtag` on the client. The GA4 measurement_id and API
  secret stay on the server.

  Forward-looking surface: the GA Measurement Protocol worker exposes
  a test sink via `CodeMySpecSpex.Fixtures.attach_ga_test_subscriber/1`,
  which registers the test process to receive each outgoing payload as
  `{:ga_measurement_protocol, payload}`. Delivery is fire-and-forget
  per PM direction, so the spec asserts dispatch — not GA's
  acknowledgement.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "Browser-triggered activation events reach GA via Measurement Protocol" do
    scenario "Browser-triggered activation events arrive in Google Analytics" do
      given_ "the user mounts /app", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "an onboarding_panel_viewed payload is dispatched to GA via Measurement Protocol",
            context do
        user_id_str = to_string(context.user.id)

        assert_receive {:ga_measurement_protocol,
                        %{events: [%{name: "onboarding_panel_viewed"} | _]} = payload},
                       1_000

        identifier =
          payload[:user_id] || payload[:client_id] || payload["user_id"] || payload["client_id"]

        assert identifier == user_id_str or identifier == context.user.id,
               "expected GA payload to identify user #{user_id_str}, got: #{inspect(identifier)}"

        {:ok, context}
      end

      when_ "the user clicks the copy button on step 1", context do
        context.view
        |> element("[data-test='copy-step-1']")
        |> render_click()

        {:ok, context}
      end

      then_ "an install_step_copied payload is dispatched to GA via Measurement Protocol",
            context do
        assert_receive {:ga_measurement_protocol,
                        %{events: [%{name: "install_step_copied", params: params} | _]}},
                       1_000

        assert params["step"] == 1 or params[:step] == 1

        {:ok, context}
      end
    end
  end
end
