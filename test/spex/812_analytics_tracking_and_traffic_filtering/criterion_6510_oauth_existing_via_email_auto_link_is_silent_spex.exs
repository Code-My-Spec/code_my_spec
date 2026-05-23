defmodule CodeMySpecSpex.Story812.Criterion6510Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6510 — Rule 3: OAuth :existing via email auto-link is
  silent — no sign_up dispatched.

  Negative cassette assertion (companion to 6509). When no
  provider-identity match exists but the OAuth email matches an
  existing users row, `find_or_register_by_email` returns the
  existing user with `:existing` and the integration is auto-linked.
  Returning users must never re-trigger `:sign_up`.

  Setup: pre-create a user with the email the OAuth callback will
  carry, but NO matching Google integration. Then drive the callback
  — the email-match path hits.

  ## Recording

      mix test test/spex/812_.../criterion_6510_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette
  import CodeMySpecSpex.GaAssertions, only: [with_ga_plug: 2]

  alias CodeMySpecSpex.{Fixtures, OAuthHelpers}

  @cassette_name "812_oauth_email_auto_link_silent"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "OAuth :existing via email auto-link is silent" do
    scenario "email match on a user with no Google integration fires no sign_up" do
      given_ "an existing user with no Google integration", context do
        unique = System.unique_integer([:positive])
        email = "google-emailmatch-812-#{unique}@example.com"

        user = Fixtures.user_fixture(%{email: email})

        user_claims = %{
          "sub" => "google-sub-812-email-#{unique}",
          "email" => email,
          "email_verified" => true,
          "name" => "OAuth Email Match"
        }

        oauth_cassette = "google_812_oauth_email_link_#{unique}"
        OAuthHelpers.build_google_cassette!(oauth_cassette, user_claims)

        {:ok,
         context
         |> Map.put(:user, user)
         |> Map.put(:oauth_cassette, oauth_cassette)}
      end

      when_ "the OAuth callback completes with that matching email", context do
        with_cassette @cassette_name, cassette_opts(), fn ga_plug ->
          with_ga_plug(ga_plug, fn ->
            OAuthHelpers.do_google_callback(
              Phoenix.ConnTest.build_conn(),
              context.oauth_cassette,
              "state-812-email"
            )
          end)
        end

        {:ok, context}
      end

      then_ "the cassette contains no sign_up MP POSTs", context do
        assert_no_mp_event(@cassette_name, "sign_up", @cassette_dir)
        {:ok, context}
      end
    end
  end

  defp assert_no_mp_event(cassette_name, event_name, cassette_dir) do
    path = Path.join(cassette_dir, cassette_name <> ".json")
    json = File.read!(path)
    data = Jason.decode!(json)
    interactions = data["interactions"] || []

    offenders =
      Enum.filter(interactions, fn interaction ->
        request = interaction["request"] || %{}

        request["method"] == "POST" and
          is_binary(request["uri"]) and
          String.starts_with?(request["uri"], "https://www.google-analytics.com/mp/collect") and
          (request["body_json"]["events"] || [])
          |> Enum.any?(&(&1["name"] == event_name))
      end)

    if offenders == [] do
      :ok
    else
      ExUnit.Assertions.flunk("""
      Expected zero #{event_name} MP POSTs in cassette #{path}, but found #{length(offenders)}:

      #{Enum.map_join(offenders, "\n", fn i -> "  " <> inspect(i["request"]["body_json"]) end)}
      """)
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
