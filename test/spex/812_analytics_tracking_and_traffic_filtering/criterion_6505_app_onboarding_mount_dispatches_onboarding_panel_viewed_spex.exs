defmodule CodeMySpecSpex.Story812.Criterion6505Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6505 — Rule 2: /app onboarding mount dispatches
  `:onboarding_panel_viewed` with the user's id.

  Authenticated LiveView mount pattern: an authenticated user lands on
  /app, AppLive.Overview mounts, and Analytics.dispatch fires
  `:onboarding_panel_viewed` with `user_id: user.id`. We verify the
  cassette captured the MP POST and that `user_id` matches the
  logged-in user.

  ## Recording

      mix test test/spex/812_.../criterion_6505_*.exs --include ga_cassette_record

  Cassette: `test/cassettes/analytics/812_onboarding_panel_viewed.json`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_onboarding_panel_viewed"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  setup :register_log_in_setup_account

  spex "Authenticated /app mount dispatches :onboarding_panel_viewed" do
    scenario "the cassette captures the MP POST with the logged-in user_id" do
      given_ "an authenticated user", context do
        {:ok, context}
      end

      when_ "the user opens /app", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn ->
            {:ok, _lv, _html} = live(context.conn, "/app")
          end)
        end

        {:ok, context}
      end

      then_ "the cassette captured onboarding_panel_viewed with the logged-in user_id",
            context do
        assert_cassette_contains_mp_event(@cassette_name, "onboarding_panel_viewed",
          user_id: context.user.id,
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
      match_requests_on: [:method, :uri, :body],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        {~r/api_secret=[^&\s"]+/, "api_secret=<REDACTED>"}
      ]
    ]
  end
end
