defmodule CodeMySpecSpex.Story698.Criterion6046Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6046 — Rule: Once any CLI has joined Presence, the
  onboarding component renders minimized by default on subsequent
  loads, but remains accessible by clicking to expand.

  Setup: register a user, simulate a historical CLI presence join via
  `Phoenix.ChannelTest` — the same channel surface the production CLI
  hits — then leave the channel so the user reads as "previously
  connected, not currently connected." Mount /app and assert the
  onboarding card renders minimized; click the toggle and assert the
  install steps become visible.

  Forward-looking modules referenced (must exist for this spec to run):
    * CodeMySpecWeb.UserSocket — socket handler exposing the CLI channel
    * CodeMySpecWeb.CliChannel — channel module that tracks CLI presence
      under topic "cli:user:<id>"
  """

  use CodeMySpecSpex.Case
  use Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Previously-connected user sees the onboarding component minimized" do
    scenario "Previously-connected user sees the onboarding component minimized" do
      given_ "the user's CLI has joined Presence at some point in the past", context do
        {:ok, _reply, channel_socket} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
          |> subscribe_and_join(CodeMySpecWeb.CliChannel, "cli:user:#{context.user.id}", %{})

        wait_for_channel(channel_socket)

        Process.flag(:trap_exit, true)
        :ok = close(channel_socket)

        {:ok, context}
      end

      given_ "the user mounts /app", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the onboarding card renders in its minimized state", context do
        assert has_element?(
                 context.view,
                 "[data-test='onboarding-card'][data-state='minimized']"
               ),
               "expected the onboarding card to render minimized for a previously-connected user"

        {:ok, context}
      end

      then_ "the install steps are not displayed", context do
        # Anchor: prove the card actually rendered before refuting its contents.
        assert has_element?(context.view, "[data-test='onboarding-card']"),
               "expected the onboarding card to be present before checking step visibility"

        for n <- 1..3 do
          refute has_element?(context.view, "[data-test='install-step-#{n}']"),
                 "did not expect install-step-#{n} in the minimized card"
        end

        {:ok, context}
      end

      when_ "the user clicks the expand toggle", context do
        context.view
        |> element("[data-test='onboarding-toggle']")
        |> render_click()

        {:ok, context}
      end

      then_ "the install steps become visible", context do
        for n <- 1..3 do
          assert has_element?(context.view, "[data-test='install-step-#{n}']"),
                 "expected install-step-#{n} to be visible after expanding"
        end

        {:ok, context}
      end
    end
  end
end
