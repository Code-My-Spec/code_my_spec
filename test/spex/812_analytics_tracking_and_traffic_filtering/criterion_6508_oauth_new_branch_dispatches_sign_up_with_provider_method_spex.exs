defmodule CodeMySpecSpex.Story812.Criterion6508Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6508 — Rule 3: OAuth :new branch dispatches sign_up with
  provider method.

  Nested-cassette pattern: the OAuth callback drives Assent through
  its own pre-recorded cassette (`google_812_oauth_new_<n>.json`)
  while the GA MP POST is captured in our cassette
  (`812_oauth_signup_new.json`). The two HTTP clients use different
  Application env settings, so the plug-config doesn't conflict.

  ## Recording

      mix test test/spex/812_.../criterion_6508_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  alias CodeMySpecSpex.OAuthHelpers

  @cassette_name "812_oauth_signup_new"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "OAuth :new branch dispatches sign_up with provider method" do
    scenario "a brand-new Google OAuth signup fires sign_up with method=oauth_google" do
      given_ "a Google OAuth cassette for a brand-new email", context do
        unique = System.unique_integer([:positive])

        user_claims = %{
          "sub" => "google-sub-812-#{unique}",
          "email" => "google-812-#{unique}@example.com",
          "email_verified" => true,
          "name" => "OAuth Analytics New User"
        }

        oauth_cassette = "google_812_oauth_new_#{unique}"
        OAuthHelpers.build_google_cassette!(oauth_cassette, user_claims)

        {:ok, Map.put(context, :oauth_cassette, oauth_cassette)}
      end

      when_ "the Google OAuth callback completes", context do
        with_cassette @cassette_name, cassette_opts(), fn ga_plug ->
          with_ga_plug(ga_plug, fn ->
            OAuthHelpers.do_google_callback(
              Phoenix.ConnTest.build_conn(),
              context.oauth_cassette,
              "state-812-#{System.unique_integer([:positive])}"
            )
          end)
        end

        {:ok, context}
      end

      then_ "the cassette captured sign_up with method=oauth_google", context do
        assert_cassette_contains_mp_event(@cassette_name, "sign_up",
          expected_params: %{"method" => "oauth_google"},
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
