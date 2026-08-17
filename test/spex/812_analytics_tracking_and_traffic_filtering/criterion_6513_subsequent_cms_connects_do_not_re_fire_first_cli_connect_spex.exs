defmodule CodeMySpecSpex.Story812.Criterion6513Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6513 — Rule 4: Subsequent cms connects do not re-fire
  `:first_cli_connect`.

  Telemetry-subscriber pattern for the negative assertion. When
  `cli_first_connected_at` is already set, the next CliChannel join
  MUST NOT fire `:first_cli_connect`. Otherwise GA re-counts the
  user as a fresh CLI connect on every login.

  Setup: pre-set `cli_first_connected_at` via
  `UsersFixtures.mark_cli_first_connected/1`.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup %{user: user} = context do
    :ok = Fixtures.mark_cli_first_connected(user)
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    {:ok, context}
  end

  spex "Subsequent cms connects do not re-fire :first_cli_connect" do
    scenario "channel join on a previously-connected user fires no :first_cli_connect" do
      given_ "a user whose cli_first_connected_at is already set", context do
        {:ok, context}
      end

      when_ "they run cms again (subsequent CliChannel join)", context do
        {:ok, _reply, channel_socket} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
          |> subscribe_and_join(
            CodeMySpecWeb.CliChannel,
            "cli:user:#{context.user.id}",
            %{}
          )

        wait_for_channel(channel_socket)
        {:ok, context}
      end

      then_ "no :first_cli_connect telemetry event is dispatched", context do
        refute_receive {:ga_measurement_protocol, %{events: [%{name: "first_cli_connect"} | _]}},
                       250

        {:ok, context}
      end
    end
  end
end
