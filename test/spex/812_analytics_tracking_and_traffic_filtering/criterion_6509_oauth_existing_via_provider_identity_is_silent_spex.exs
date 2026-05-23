defmodule CodeMySpecSpex.Story812.Criterion6509Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6509 — Rule 3: OAuth :existing via provider identity is
  silent — no sign_up dispatched, no MP event.

  Negative cassette assertion: when an existing (provider,
  provider_user_id) integration is already mapped to a user,
  `find_or_register_oauth_user/2` returns `{:ok, user, :existing}`.
  Returning users must NEVER fire `:sign_up`, otherwise GA would
  double-count signups on every subsequent login.

  Setup: pre-create the user + Google integration with a known
  `provider_user_id`, then drive the OAuth callback with the same
  `sub`. Assertion: cassette contains zero sign_up MP POSTs.

  ## Recording

      mix test test/spex/812_.../criterion_6509_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette
  import CodeMySpecSpex.GaAssertions, only: [with_ga_plug: 2]

  alias CodeMySpecSpex.{Fixtures, OAuthHelpers}

  @cassette_name "812_oauth_existing_provider_silent"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "OAuth :existing via provider identity is silent" do
    scenario "returning login fires no sign_up MP POST" do
      given_ "an existing user + Google integration", context do
        unique = System.unique_integer([:positive])
        sub = "google-sub-812-existing-#{unique}"
        email = "google-existing-812-#{unique}@example.com"

        user = Fixtures.user_fixture(%{email: email})
        # Insert a Google integration whose provider_metadata.provider_user_id
        # matches the OAuth `sub` we'll drive the callback with.
        Fixtures.user_fixture()
        # ^ ensure at least one other user exists; the lookup is on (provider,
        # provider_user_id).

        # Same pattern OAuthHelpers expects — pre-record the OAuth cassette.
        user_claims = %{
          "sub" => sub,
          "email" => email,
          "email_verified" => true,
          "name" => "OAuth Existing Returning"
        }

        oauth_cassette = "google_812_oauth_existing_#{unique}"
        OAuthHelpers.build_google_cassette!(oauth_cassette, user_claims)

        {:ok,
         context
         |> Map.put(:user, user)
         |> Map.put(:sub, sub)
         |> Map.put(:oauth_cassette, oauth_cassette)}
      end

      and_ "the integration row already maps (provider, sub) → user.id", context do
        Fixtures.google_integration_fixture(context.user, %{
          provider_metadata: %{"provider_user_id" => context.sub}
        })

        {:ok, context}
      end

      when_ "the OAuth callback completes for that same sub", context do
        with_cassette @cassette_name, cassette_opts(), fn ga_plug ->
          with_ga_plug(ga_plug, fn ->
            OAuthHelpers.do_google_callback(
              Phoenix.ConnTest.build_conn(),
              context.oauth_cassette,
              "state-812-existing"
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
