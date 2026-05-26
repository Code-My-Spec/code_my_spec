defmodule CodeMySpecSpex.Story812.Criterion6512Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6512 — Rule 4: First cms connect dispatches
  `:first_cli_connect` exactly once.

  Test-subscriber pattern: `Fixtures.attach_ga_test_subscriber/1` registers
  this test process to receive every GA Measurement Protocol payload as
  `{:ga_measurement_protocol, payload}`. We join `CliChannel` via
  `Phoenix.ChannelTest` — the same code path the CLI's WebSocket uses —
  and assert the MP payload arrives exactly once with the correct user_id.

  No cassette, no real GA round-trip. The join pattern follows
  criterion_6043 (story 698), which established the CLI-channel-join surface
  for domain-event assertions.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "First cms connect dispatches :first_cli_connect once" do
    scenario "CliChannel join for a fresh user fires one first_cli_connect MP payload" do
      given_ "a user whose cli_first_connected_at is NULL", context do
        # register_log_in_setup_account creates a fresh user; cli_first_connected_at
        # defaults to nil, so this is already satisfied.
        {:ok, context}
      end

      when_ "the user runs cms and CliChannel completes its first authenticated join",
            context do
        {:ok, _reply, channel_socket} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
          |> subscribe_and_join(
            CodeMySpecWeb.CliChannel,
            "cli:user:#{context.user.id}",
            %{}
          )

        wait_for_channel(channel_socket)
        {:ok, Map.put(context, :channel_socket, channel_socket)}
      end

      then_ "a first_cli_connect MP payload arrives for this user", context do
        user_id = context.user.id

        assert_receive {:ga_measurement_protocol,
                        %{
                          user_id: mp_user_id,
                          events: [%{name: "first_cli_connect"} | _]
                        }},
                       1_000

        assert to_string(mp_user_id) == to_string(user_id),
               "Expected first_cli_connect MP payload user_id=#{user_id}, got: #{inspect(mp_user_id)}"

        {:ok, context}
      end

      then_ "no second first_cli_connect MP payload arrives", context do
        refute_receive {:ga_measurement_protocol,
                        %{events: [%{name: "first_cli_connect"} | _]}},
                       200

        {:ok, context}
      end
    end
  end
end
