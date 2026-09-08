defmodule CodeMySpecSpex.Story701.Criterion6070Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6070 — Rule: On receipt, the dashboard's `CliChannel`
  relays each event into `CodeMySpec.Analytics.dispatch/3` with
  origin `:server` so it rides the existing Measurement Protocol path
  to Google Analytics.

  Verified by attaching the GA test subscriber and pushing one
  activation_event over the channel — the server's CliChannel
  handle_in dispatches with origin :server, the GA telemetry handler
  builds a Measurement Protocol payload and forwards it to the test
  subscriber.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  setup context do
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

  spex "CliChannel relays activation events to GA via Analytics" do
    scenario "CliChannel routes received activation events through Analytics" do
      when_ "the local app pushes a local_init_complete event over the channel", context do
        Phoenix.ChannelTest.push(context.channel_socket, "activation_event", %{
          "name" => "local_init_complete",
          "payload" => %{"user_id" => context.user.id}
        })

        {:ok, context}
      end

      then_ "the GA test subscriber receives a Measurement Protocol payload for the event",
            context do
        user_id_str = to_string(context.user.id)

        assert_receive {:ga_measurement_protocol,
                        %{events: [%{name: "local_init_complete"} | _]} = payload},
                       1_000

        identifier = MapAccess.get(payload, :user_id) || MapAccess.get(payload, :client_id)

        assert identifier == user_id_str or identifier == context.user.id,
               "expected GA payload to identify user #{user_id_str}; got: #{inspect(identifier)}"

        {:ok, context}
      end
    end
  end
end
