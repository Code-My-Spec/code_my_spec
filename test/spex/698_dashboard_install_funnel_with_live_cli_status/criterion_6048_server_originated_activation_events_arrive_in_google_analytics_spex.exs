defmodule CodeMySpecSpex.Story698.Criterion6048Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6048 — Rule: Activation events reach Google Analytics,
  including events that originate on the server.

  The first_cli_connect event fires from server-side code (Presence
  join handler) — there is no browser open at the moment of emission,
  so gtag isn't an option. The Measurement Protocol path delivers the
  event via a server-to-GA HTTP POST.

  Forward-looking surface: the GA Measurement Protocol worker exposes
  a test sink via `CodeMySpecSpex.Fixtures.attach_ga_test_subscriber/1`,
  which registers the test process to receive each outgoing payload as
  `{:ga_measurement_protocol, payload}`. Delivery is fire-and-forget
  per PM direction, so the spec asserts dispatch — not GA's
  acknowledgement.
  """

  use CodeMySpecSpex.Case
  use Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "Server-originated activation events reach GA via Measurement Protocol" do
    scenario "Server-originated activation events arrive in Google Analytics" do
      when_ "the user's CLI joins Presence for the first time", context do
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

      then_ "a first_cli_connect payload is dispatched to GA via Measurement Protocol", context do
        user_id_str = to_string(context.user.id)

        assert_receive {:ga_measurement_protocol,
                        %{events: [%{name: "first_cli_connect"} | _]} = payload},
                       1_000

        # Measurement Protocol carries `client_id` (or `user_id`) so GA can
        # bind the event to the right user. Either field is acceptable;
        # assert at least one is populated and identifies our user.
        identifier = payload[:user_id] || payload[:client_id] || payload["user_id"] || payload["client_id"]

        assert identifier == user_id_str or identifier == context.user.id,
               "expected GA payload to identify user #{user_id_str}, got: #{inspect(identifier)}"

        {:ok, context}
      end
    end
  end
end
