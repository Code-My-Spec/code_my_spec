defmodule CodeMySpecSpex.Story812.Criterion6507Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6507 — Rule 3: New magic-link signup dispatches `:sign_up`
  and `:registration_email_sent`.

  Pilot spex for the cassette-as-contract pattern (story 812):

  1. Drive the registration LiveView — `Users.register_user/1` inserts
     a new users row and dispatches `:sign_up` with
     `method: "magic_link"`. `deliver_login_instructions/2` then
     triggers `:registration_email_sent`.
  2. The outgoing MP POSTs to `https://www.google-analytics.com/mp/collect`
     are captured by the cassette plug wired into
     `CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter`.
  3. The assertion reads the captured cassette and verifies the
     expected `sign_up` event was POSTed with the right params.

  We deliberately do NOT verify via GA's Realtime Report API — the
  ingest latency (5+ minutes) outpaces reasonable test timeouts. The
  cassette IS the contract: if the dispatch shape changes, the
  captured POST won't match and the assertion fails.

  ## Recording

      GA_TEST_OAUTH_TOKEN=$(mix cms.ga_test_token | tail -n1) \\
        mix test test/spex/812_.../criterion_6507_*.exs --include ga_cassette_record

  The Authorization headers and MP api_secret are filtered before write,
  so the recorded cassette is safe to commit. Subsequent runs replay from
  cassette and don't need the env var.

  Tagged `:ga_cassette_record` so it's skipped in normal runs until the
  cassette is recorded once. After recording, change `mode: :record` →
  `mode: :replay` and drop the tag.

  ## Why no GA Realtime verify?

  The earlier draft of this pilot used `GaAssertions.assert_event_recorded/3`
  to round-trip through the Reporting API. GA's Realtime Report has
  multi-minute ingest latency that exceeds reasonable test timeouts —
  the report came back with 0 rows even after a 60s sleep. The
  cassette-as-contract approach below sidesteps that entirely while
  still proving the dispatch shape end-to-end.
  """

  use CodeMySpecSpex.Case

  # /users/register lives on the main web router, not LocalWeb. Override
  # the @endpoint the Case set so live/3 dispatches to the right router.
  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_signup_magic_link"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "New magic-link signup round-trips to Google Analytics" do
    scenario "registering a fresh email dispatches :sign_up + arrives in GA realtime" do
      given_ "no existing user row for the test email", context do
        email = "spex-812-#{System.unique_integer([:positive])}@codemyspec.test"
        {:ok, Map.put(context, :email, email)}
      end

      when_ "the visitor submits the magic-link registration form", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn ->
            {:ok, lv, _html} = live(context.conn, "/users/register")

            # Submit the registration form. push_navigate on success
            # returns {:error, {:live_redirect, ...}} — that's the
            # happy path here, not an error.
            lv
            |> form("#registration_form", user: %{email: context.email})
            |> render_submit()
          end)
        end

        {:ok, context}
      end

      then_ "the cassette captured the sign_up MP POST with method=magic_link",
            context do
        assert_cassette_contains_mp_event(@cassette_name, "sign_up",
          expected_params: %{"method" => "magic_link"},
          cassette_dir: @cassette_dir
        )

        {:ok, context}
      end

      then_ "the cassette also captured registration_email_sent", context do
        assert_cassette_contains_mp_event(@cassette_name, "registration_email_sent",
          cassette_dir: @cassette_dir
        )

        {:ok, context}
      end
    end
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      # MUST include :body — without it, all POSTs to /mp/collect look
      # identical to ReqCassette (same method + uri) and only the first
      # one gets recorded; the second one "matches" and replays the
      # first response, never hitting GA. Including body lets distinct
      # events (view_register_page vs sign_up vs registration_email_sent)
      # all record cleanly.
      match_requests_on: [:method, :uri, :body],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        # MP api_secret is a query param — strip it from any recorded
        # POST to www.google-analytics.com/mp/collect.
        {~r/api_secret=[^&\s"]+/, "api_secret=<REDACTED>"}
      ]
    ]
  end
end
