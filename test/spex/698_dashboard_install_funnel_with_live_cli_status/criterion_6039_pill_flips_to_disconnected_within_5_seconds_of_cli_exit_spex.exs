defmodule CodeMySpecSpex.Story698.Criterion6039Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6039 — Rule: Connection status updates an open dashboard
  within 5 seconds of a CLI leaving.

  The 5-second SLO is a real-world latency commitment; in a spec the
  Presence leave broadcast fires immediately. What this spec enforces
  is that closing the only live CLI channel causes the LiveView to
  re-render the pill from "Connected" to "Disconnected".
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  # The pill lives on the plugin rung, which needs the earlier rungs done —
  # the ladder needs an active project (pill renders on both the active
  # install panel and the collapsed Done tile).
  setup :setup_active_project

  spex "Connection status reflects a CLI leaving within 5 seconds" do
    scenario "Pill flips to disconnected within 5 seconds of CLI exit" do
      given_ "the user has /app open and one CLI session is connected", context do
        {:ok, _reply, channel_socket} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
          |> subscribe_and_join(
            CodeMySpecWeb.CliChannel,
            "cli:user:#{context.user.id}",
            %{}
          )

        wait_for_channel(channel_socket)

        {:ok, view, _html} = live(context.conn, "/app")

        {:ok, Map.merge(context, %{view: view, channel_socket: channel_socket})}
      end

      then_ "the pill initially reads Connected", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "Connected",
               "expected initial pill to read Connected with one CLI joined, got: #{pill}"

        {:ok, context}
      end

      when_ "the user's only CLI process exits", context do
        Process.flag(:trap_exit, true)
        :ok = close(context.channel_socket)
        {:ok, context}
      end

      then_ "the pill displays a disconnected state", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        # Audit C9 reframe: pill text now blames the user environment
        # ("Claude Code not running") rather than the product ("Disconnected"),
        # since the only thing that takes Presence offline is the CLI
        # leaving. Anchor on the data-state attribute (stable contract)
        # plus the new copy.
        assert pill =~ ~s|data-state="disconnected"|,
               "expected the pill to render in the disconnected state after the only CLI exited, got: #{pill}"

        assert pill =~ "Claude Code not running",
               "expected the pill text to surface the disconnected cause, got: #{pill}"

        {:ok, context}
      end
    end
  end
end
