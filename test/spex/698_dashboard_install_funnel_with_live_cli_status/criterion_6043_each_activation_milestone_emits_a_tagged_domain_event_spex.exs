defmodule CodeMySpecSpex.Story698.Criterion6043Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6043 — Rule: Activation milestones emit domain events.

  Narrowed to first_cli_connect only. The browser milestones
  (onboarding_panel_viewed, install_step_copied) moved to client-side
  gtag in the story-812 hybrid migration — they no longer fire as server
  domain events and are covered by story 812's criteria. Criterion 6044
  (browser-via-MP) was deleted for the same reason.

  first_cli_connect remains a server-side domain event: the CLI channel
  join triggers it through CodeMySpec.Analytics when the user connects for
  the first time. GA forwarding via MP is covered by criterion_6048.

  Forward-looking surface: events flow through `CodeMySpec.Analytics`,
  the project's domain-event dispatcher. The spex bridge
  (`CodeMySpecSpex.Fixtures.attach_analytics_test_subscriber/1`)
  registers the test process to receive each dispatched event as
  `{:analytics_event, name, payload}`. GA forwarding is out of scope
  here — criterion 6048 covers that path.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.attach_analytics_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_analytics_test_subscriber(self()) end)
    :ok
  end

  spex "Activation milestones each emit a tagged domain event" do
    scenario "First CLI Presence join emits a first_cli_connect event" do
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

      then_ "a first_cli_connect event is emitted for that user", context do
        user_id = context.user.id

        assert_receive {:analytics_event, :first_cli_connect, %{user_id: ^user_id}}, 1_000

        {:ok, context}
      end
    end
  end
end
