defmodule CodeMySpecSpex.Story698.Criterion6043Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6043 — Rule: Activation milestones emit domain events:
  onboarding panel viewed, each install step copied, and first CLI
  connect.

  Each milestone is its own scenario so a regression in one path
  doesn't mask the others.

  Forward-looking surface: events flow through `CodeMySpec.Analytics`,
  the project's domain-event dispatcher. The spex bridge
  (`CodeMySpecSpex.Fixtures.attach_analytics_test_subscriber/1`)
  registers the test process to receive each dispatched event as
  `{:analytics_event, name, payload}`. GA forwarding is out of scope
  here — criteria 6044/6048 cover that path.
  """

  use CodeMySpecSpex.Case
  use Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    :ok = Fixtures.attach_analytics_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_analytics_test_subscriber(self()) end)
    :ok
  end

  spex "Activation milestones each emit a tagged domain event" do
    scenario "Mounting /app emits an onboarding_panel_viewed event" do
      when_ "the user mounts /app", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "an onboarding_panel_viewed event is emitted for that user", context do
        user_id = context.user.id

        assert_receive {:analytics_event, :onboarding_panel_viewed, %{user_id: ^user_id}}, 500

        {:ok, context}
      end
    end

    scenario "Clicking a copy button emits an install_step_copied event" do
      given_ "the user is on /app with the onboarding component expanded", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the user clicks the copy button on step 2", context do
        context.view
        |> element("[data-test='copy-step-2']")
        |> render_click()

        {:ok, context}
      end

      then_ "an install_step_copied event is emitted carrying the step number", context do
        user_id = context.user.id

        assert_receive {:analytics_event, :install_step_copied,
                        %{user_id: ^user_id, step: 2}},
                       500

        {:ok, context}
      end
    end

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
