defmodule CodeMySpecSpex.Story698.Criterion6046Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6046 — Rule: Once any CLI has joined Presence, the plugin
  step renders collapsed on subsequent loads — a compact Done tile that
  stays collapsed (no re-expand affordance) but carries the live
  CLI-status pill, so current presence is always visible at a glance.

  Setup: register a user with an active project, simulate a historical
  CLI presence join via `Phoenix.ChannelTest` — the same channel surface
  the production CLI hits — then leave the channel so the user reads as
  "previously connected, not currently connected." Mount /app and assert
  the plugin rung renders as the collapsed Done tile whose pill reflects
  the CURRENT (disconnected) presence, with no expanded install panel.

  Forward-looking modules referenced (must exist for this spec to run):
    * CodeMySpecWeb.UserSocket — socket handler exposing the CLI channel
    * CodeMySpecWeb.CliChannel — channel module that tracks CLI presence
      under topic "cli:user:<id>"
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  # The plugin rung only reaches its collapsed Done state once the earlier
  # rungs are done — the ladder needs an active project.
  setup :setup_active_project

  spex "Previously-connected user sees the onboarding component minimized" do
    scenario "Previously-connected user sees the collapsed plugin tile with a live pill" do
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

      then_ "the plugin rung renders as the collapsed Done tile", context do
        assert has_element?(context.view, "[data-test='plugin-rung'][data-state='done']"),
               "expected the plugin rung to render collapsed (done) for a previously-connected user"

        {:ok, context}
      end

      then_ "the collapsed tile carries the live pill reflecting current presence", context do
        # Previously connected but no live session right now → the pill must
        # say so instead of a stale static "Connected".
        assert has_element?(
                 context.view,
                 "[data-test='plugin-rung'] [data-test='cli-status-pill'][data-state='disconnected']"
               ),
               "expected the collapsed tile's pill to reflect the disconnected presence"

        {:ok, context}
      end

      then_ "no expanded install panel renders", context do
        refute has_element?(context.view, "[data-test='onboarding-card']"),
               "expected no install panel — the plugin step stays collapsed once connected"

        {:ok, context}
      end
    end
  end
end
