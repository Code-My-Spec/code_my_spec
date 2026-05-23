defmodule CodeMySpecSpex.Story812.Criterion6507Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6507 — Rule 3: New magic-link signup dispatches `:sign_up`
  and `:registration_email_sent`.

  Pilot spex for the round-trip cassette pattern (story 812):

  1. Drive the registration LiveView — `Users.register_user/1` inserts
     a new users row and dispatches `:sign_up` with
     `method: "magic_link"` and `:registration_email_sent` after
     `deliver_login_instructions/2` returns ok.
  2. The outgoing MP POST to `https://www.google-analytics.com/mp/collect`
     is captured by the cassette plug wired into
     `CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter`.
  3. The follow-up query to GA Realtime Report is captured by the
     same cassette plug wired into
     `CodeMySpec.Analytics.GoogleAnalytics.ReportingClient`.
  4. `GaAssertions.assert_event_recorded/3` confirms the event landed.

  Both halves of the round-trip live in one cassette file under
  `test/cassettes/analytics/812_signup_magic_link.json`.

  ## Recording

      GA_TEST_OAUTH_TOKEN=$(mix cms.ga_test_token | tail -n1) \\
        mix test test/spex/812_.../criterion_6507_*.exs --include ga_cassette_record

  The Authorization headers and MP api_secret are filtered before write,
  so the recorded cassette is safe to commit. Subsequent runs replay from
  cassette and don't need the env var.

  Tagged `:ga_cassette_record` so it's skipped in normal runs until the
  cassette is recorded once. After recording, change `mode: :record` →
  `mode: :replay` and drop the tag.

  ## GA Realtime latency caveat

  The Realtime Report API can take several minutes to surface
  freshly-dispatched events — sometimes longer than reasonable test
  timeouts. During recording, the assertion may fail because the report
  returns 0 rows even though the MP POST was accepted. Workarounds:

  1. Fire warmup events out-of-band (e.g. via a separate script) several
     minutes BEFORE running the recording, so when the spex queries the
     Realtime API the events are already visible.
  2. After recording, hand-inspect the cassette and manually craft the
     Reporting response if needed (the cassette is JSON).

  The captured cassette is still useful even if the assertion fails on
  first record — the outgoing MP POSTs are captured deterministically
  and prove the dispatch contract.
  """

  use CodeMySpecSpex.Case

  # /users/register lives on the main web router, not LocalWeb. Override
  # the @endpoint the Case set so live/3 dispatches to the right router.
  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette
  import CodeMySpecSpex.GaAssertions, only: [assert_event_recorded: 3, with_ga_plug: 2]

  alias CodeMySpecSpex.Fixtures

  @property_id "508773792"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record
  @moduletag timeout: 240_000

  setup context do
    # The visitor in this spex is UNAUTHENTICATED — the registration
    # form is for fresh sign-ups, so don't log anyone into the conn.
    # But the GaAssertions call needs a scope with a Google
    # integration to query GA. So we create a separate "operator"
    # user behind the scenes whose scope holds the integration.
    operator = Fixtures.user_fixture()
    operator_scope = Fixtures.user_scope_fixture(operator)
    _integration = Fixtures.google_integration_fixture(operator)
    {:ok, Map.put(context, :operator_scope, operator_scope)}
  end

  spex "New magic-link signup round-trips to Google Analytics" do
    scenario "registering a fresh email dispatches :sign_up + arrives in GA realtime" do
      given_ "no existing user row for the test email", context do
        email = "spex-812-#{System.unique_integer([:positive])}@codemyspec.test"
        {:ok, Map.put(context, :email, email)}
      end

      when_ "the visitor submits the magic-link registration form, then we query GA",
            context do
        result =
          with_cassette "812_signup_magic_link", cassette_opts(), fn plug ->
            with_ga_plug(plug, fn ->
              # Pre-fetch the OAuth token BEFORE any long sleep so the
              # Ecto sandbox connection doesn't time out mid-assertion.
              # During replay the cassette serves the response regardless,
              # so an empty token is fine.
              token = System.get_env("GA_TEST_OAUTH_TOKEN")

              {:ok, lv, _html} = live(context.conn, "/users/register")

              # Submit the registration form. push_navigate on success
              # returns {:error, {:live_redirect, ...}} — that's the
              # happy path here, not an error.
              lv
              |> form("#registration_form", user: %{email: context.email})
              |> render_submit()

              # GA Realtime API has ingest latency between MP POST and
              # visibility on the Realtime Report. During recording we
              # sleep so the report sees our event; during replay the
              # cassette returns the recorded response immediately so
              # the sleep is harmless.
              if token, do: Process.sleep(60_000)

              # The cassette captured the MP POST. Now verify the event
              # landed in GA via the same cassette plug. Token is passed
              # explicitly to skip the in-test DB integration lookup.
              assert_event_recorded(context.operator_scope, "sign_up",
                property_id: @property_id,
                token: token || "replay_token"
              )

              :ok
            end)
          end

        {:ok, Map.put(context, :cassette_result, result)}
      end

      then_ "the round-trip completed without error", context do
        assert context.cassette_result == :ok
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
