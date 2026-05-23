defmodule CodeMySpecSpex.Story812.Criterion6514Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6514 — Rule 5: Every dispatch traces from handler entry
  through MP delivery outcome.

  Log-capture pattern: drive a real dispatch and assert the structured
  log lines fire at handler entry and MP delivery. Uses ExUnit's
  `capture_log/1` to grab the Logger output and matches against the
  structured-field shape — `event=`, `user_id=`, `mp_status=`.

  Cassette captures the MP POST (so the success path actually reaches
  the HTTPAdapter, which is where `mp_status=` logs).
  """

  use CodeMySpecSpex.Case

  import ExUnit.CaptureLog
  import ReqCassette
  import CodeMySpecSpex.GaAssertions, only: [with_ga_plug: 2]

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  @cassette_name "812_dispatch_log_trace"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "Every dispatch traces from handler entry through MP delivery outcome" do
    scenario "logs include event=, user_id=, mp_status= for one sign_up dispatch" do
      given_ "a synthetic sign_up dispatch ready to fire", context do
        {:ok, Map.put(context, :user_id, System.unique_integer([:positive]))}
      end

      when_ "Analytics.dispatch fires and the handler runs end-to-end", context do
        log =
          capture_log(fn ->
            with_cassette @cassette_name, cassette_opts(), fn plug ->
              with_ga_plug(plug, fn ->
                Fixtures.dispatch_analytics_event(:sign_up, %{
                  user_id: context.user_id,
                  method: "log_trace_test"
                })
              end)
            end
          end)

        {:ok, Map.put(context, :log, log)}
      end

      then_ "a handler-entry log line carries event= and user_id=", context do
        assert context.log =~ "GA MP handler received event",
               "expected handler-entry log line"

        # logfmt keys can land in different formats; structured metadata is
        # attached, so substring matching on `event=` and `user_id=` is the
        # cheapest reliable check.
        assert context.log =~ "event=",
               "expected event= metadata key in handler-entry log"

        assert context.log =~ "user_id=#{context.user_id}",
               "expected user_id=#{context.user_id} in handler-entry log"

        {:ok, context}
      end

      then_ "an MP-delivery log line carries mp_status=", context do
        # On success we log "GA MP delivery ok" with mp_status=2xx.
        # On any non-success we log a warning with mp_status=<error tag>.
        # Either way, an mp_status= field must appear.
        assert context.log =~ "mp_status=",
               "expected mp_status= in MP delivery log"

        {:ok, context}
      end
    end
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri, :body],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        {~r/api_secret=[^&\s"]+/, "api_secret=<REDACTED>"}
      ]
    ]
  end
end
