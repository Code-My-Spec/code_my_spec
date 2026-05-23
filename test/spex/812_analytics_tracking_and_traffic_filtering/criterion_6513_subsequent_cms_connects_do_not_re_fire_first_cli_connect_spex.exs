defmodule CodeMySpecSpex.Story812.Criterion6513Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6513 — Rule 4: Subsequent cms connects do not re-fire
  `:first_cli_connect`.

  Negative cassette assertion: when `cli_first_connected_at` is
  already set, the next CliChannel join MUST NOT fire
  `:first_cli_connect`. Otherwise GA would re-count the user as a
  fresh CLI connect every login.

  Setup: pre-set `cli_first_connected_at` on the test user via the
  same update path the first-connect would have used.

  ## Recording

      mix test test/spex/812_.../criterion_6513_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  import ReqCassette
  import CodeMySpecSpex.GaAssertions, only: [with_ga_plug: 2]

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  @cassette_name "812_subsequent_cli_connect_silent"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  setup :register_log_in_setup_account

  setup %{user: user} = context do
    # Mark this user as having already first-connected. The CliChannel
    # short-circuit looks at the column value.
    :ok = Fixtures.mark_cli_first_connected(user)
    {:ok, context}
  end

  spex "Subsequent cms connects do not re-fire :first_cli_connect" do
    scenario "channel join on a previously-connected user records no first_cli_connect" do
      given_ "a user whose cli_first_connected_at is already set", context do
        {:ok, context}
      end

      when_ "they run cms again (subsequent CliChannel join)", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn ->
            {:ok, _reply, channel_socket} =
              CodeMySpecWeb.UserSocket
              |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
              |> subscribe_and_join(
                CodeMySpecWeb.CliChannel,
                "cli:user:#{context.user.id}",
                %{}
              )

            wait_for_channel(channel_socket)
          end)
        end

        {:ok, context}
      end

      then_ "the cassette contains no first_cli_connect MP POSTs", context do
        assert_no_mp_event(@cassette_name, "first_cli_connect", @cassette_dir)
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
