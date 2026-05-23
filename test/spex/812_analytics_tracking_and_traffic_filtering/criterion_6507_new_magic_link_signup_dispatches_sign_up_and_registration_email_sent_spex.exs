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

  The cassette currently doesn't exist. To record:

      GA_TEST_OAUTH_TOKEN=<real-google-access-token-with-analytics.readonly> \\
        mix test test/spex/812_.../criterion_6507_*.exs --include ga_cassette_record

  The Authorization headers are filtered before write, so the recorded
  cassette is safe to commit. Subsequent runs replay from cassette and
  don't need the env var.

  Tagged `:ga_cassette_record` so it's skipped in normal runs until the
  cassette is recorded once. After recording, change `mode: :record` →
  `mode: :replay` and drop the tag.
  """

  use CodeMySpecSpex.Case

  import ReqCassette
  import CodeMySpecSpex.GaAssertions, only: [assert_event_recorded: 3, with_ga_plug: 2]

  alias CodeMySpecSpex.Fixtures

  @property_id "508773792"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  setup :register_log_in_setup_account

  setup %{user: user, scope: scope} = context do
    # The ReportingClient needs a scope with a valid Google integration
    # carrying analytics.readonly. During cassette recording the
    # GA_TEST_OAUTH_TOKEN env var supplies a real access token; during
    # replay the placeholder is fine.
    _integration = Fixtures.google_integration_fixture(user)
    {:ok, Map.put(context, :scope, scope)}
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
              {:ok, lv, _html} = live(context.conn, "/users/register")

              lv
              |> form("#registration_form", user: %{email: context.email})
              |> render_submit()

              # Synchronous dispatch — telemetry handlers run inline.
              # The cassette captured the MP POST. Now verify the
              # event landed in GA via the same cassette plug.
              assert_event_recorded(context.scope, "sign_up", property_id: @property_id)

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
      match_requests_on: [:method, :uri],
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
