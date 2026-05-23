defmodule CodeMySpecSpex.Story812.Criterion6512Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6512 — Rule 4: First cms connect dispatches
  `:first_cli_connect` exactly once.

  Phoenix.ChannelTest pattern + cassette: when a user runs `cms` for
  the first time, CliChannel detects `users.cli_first_connected_at IS
  NULL`, sets the timestamp, and dispatches `:first_cli_connect` with
  `user_id`. The MP POST lands in the cassette.

  ## Recording

      mix test test/spex/812_.../criterion_6512_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @endpoint CodeMySpecWeb.Endpoint

  @cassette_name "812_first_cli_connect"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  setup :register_log_in_setup_account

  spex "First cms connect dispatches :first_cli_connect once" do
    scenario "the cassette captures one first_cli_connect MP POST with user_id" do
      given_ "a user whose cli_first_connected_at is NULL", context do
        # register_log_in_setup_account creates a fresh user; default state
        # has cli_first_connected_at as nil.
        {:ok, context}
      end

      when_ "the user runs cms and CliChannel completes its first authenticated join",
            context do
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

      then_ "the cassette captured first_cli_connect with this user_id", context do
        assert_cassette_contains_mp_event(@cassette_name, "first_cli_connect",
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
