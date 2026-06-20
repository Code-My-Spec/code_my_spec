defmodule CodeMySpecSpex.Story812.Criterion6514Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6514 — Rule 5: Every dispatch traces from handler entry
  through MP delivery outcome.

  Log-capture pattern: drive a real dispatch WITHOUT attaching the GA test
  subscriber so the event flows through `deliver_via_http/2`, which is where
  the `mp_status=` delivery-outcome log is emitted. The test environment
  has `api_secret: nil` (GA4_MP_API_SECRET unset), so the delivery path
  reaches the missing-config branch and logs `mp_status: :missing_config`
  at `:warning` — no real HTTP call is made and no real GA key is needed.

  We use `ExUnit.CaptureLog` to capture both log lines:
  1. Handler-entry: "GA MP handler received event" (`:info`) — carries `event=` and `user_id=`.
  2. Delivery outcome: "GA MP delivery skipped: missing measurement_id or api_secret"
     (`:warning`) — carries `mp_status=`.

  Since the handler-entry log is at `:info` and the test runtime Logger level
  is `:warning`, we temporarily lower the Logger level to `:info` for the
  capture window — the same approach the original cassette spex used.

  IMPORTANT: do NOT attach the GA test subscriber in this spex — the subscriber
  short-circuits `deliver/2` before `deliver_via_http/2` is reached, which
  means the `mp_status=` delivery-outcome log would never fire.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "Every dispatch traces from handler entry through MP delivery outcome" do
    scenario "logs include event=, user_id=, mp_status= for one sign_up dispatch" do
      given_ "a synthetic sign_up dispatch ready to fire", context do
        {:ok, Map.put(context, :user_id, System.unique_integer([:positive]))}
      end

      when_ "Analytics.dispatch fires and the handler runs end-to-end", context do
        # capture_log_at_info lowers the Logger level to :info for the
        # capture window (and restores it after) so the handler-entry
        # trace, logged at :info, reaches the buffer.
        log =
          Fixtures.capture_log_at_info(fn ->
            Fixtures.dispatch_analytics_event(:sign_up, %{
              user_id: context.user_id,
              method: "log_trace_test"
            })
          end)

        {:ok, Map.put(context, :log, log)}
      end

      then_ "a handler-entry log line carries event= and user_id=", context do
        assert context.log =~ "GA MP handler received event",
               "expected handler-entry log line"

        assert context.log =~ "event=",
               "expected event= metadata key in handler-entry log"

        assert context.log =~ "user_id=#{context.user_id}",
               "expected user_id=#{context.user_id} in handler-entry log"

        {:ok, context}
      end

      then_ "an MP-delivery log line carries mp_status=", context do
        # In test, api_secret is nil so the delivery path logs
        # "GA MP delivery skipped" with mp_status: :missing_config.
        assert context.log =~ "mp_status=",
               "expected mp_status= in MP delivery log"

        {:ok, context}
      end
    end
  end
end
