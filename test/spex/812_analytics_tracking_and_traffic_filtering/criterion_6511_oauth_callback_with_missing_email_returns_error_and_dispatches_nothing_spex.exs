defmodule CodeMySpecSpex.Story812.Criterion6511Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6511 — Rule 3: OAuth callback with missing email returns
  error and dispatches nothing.

  Unit-test pattern + cassette negation: when the OAuth provider
  returns no email and no matching provider identity exists,
  `Users.find_or_register_oauth_user/2` returns
  `{:error, :missing_email}`. No users row inserts, no `:sign_up`
  dispatches.

  Drives the unit-level path directly (not the HTTP callback) because
  the empty-email case is a contract on the function, not on the
  controller. The cassette negation still proves no MP POST fired.

  ## Recording

      mix test test/spex/812_.../criterion_6511_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case

  import ReqCassette
  import CodeMySpecSpex.GaAssertions, only: [with_ga_plug: 2]

  alias CodeMySpecSpex.Fixtures

  @cassette_name "812_oauth_missing_email_silent"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "OAuth callback with missing email returns error and dispatches nothing" do
    scenario "find_or_register_oauth_user/2 with nil email is silent" do
      given_ "an OAuth callback payload with no email and no matching provider identity",
             context do
        {:ok, Map.put(context, :provider_user_id, "google-no-email-#{System.unique_integer([:positive])}")}
      end

      when_ "Users.find_or_register_oauth_user/2 is called", context do
        result =
          with_cassette @cassette_name, cassette_opts(), fn ga_plug ->
            with_ga_plug(ga_plug, fn ->
              Fixtures.find_or_register_oauth_user(
                :google,
                %{provider_user_id: context.provider_user_id, email: nil}
              )
            end)
          end

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the call returns {:error, :missing_email}", context do
        assert context.result == {:error, :missing_email}
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
      Expected zero #{event_name} MP POSTs, found #{length(offenders)}:

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
