defmodule CodeMySpecSpex.Story698.Criterion6038Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6038 — Rule: Connection status reflects live CLI presence
  and the dashboard updates within 2 seconds of a CLI joining.

  The 2-second SLO is a real-world latency commitment; in a spec the
  loopback is sub-millisecond. What this spec enforces is that the
  LiveView re-renders the pill from "Not connected" to "Connected"
  in response to a real Phoenix Presence join — no manual flag, no
  page reload.

  Forward-looking modules:
    * CodeMySpecWeb.UserSocket
    * CodeMySpecWeb.CliChannel under topic "cli:user:<id>"
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Connection status reflects live CLI presence within 2 seconds of a join" do
    scenario "Pill flips to connected within 2 seconds of CLI join" do
      given_ "the user has /app open", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the pill initially reads Not connected", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "Not connected",
               "expected initial pill to read Not connected, got: #{pill}"

        {:ok, context}
      end

      when_ "the user's CLI joins Presence", context do
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

      then_ "the pill displays Connected without a page reload", context do
        # render/1 returns the latest LiveView state — the Presence broadcast
        # should have already pushed an update over the LiveView's PubSub.
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "Connected",
               "expected the pill to read Connected after CLI join, got: #{pill}"

        refute pill =~ "Not connected",
               "expected the pill to no longer read Not connected"

        {:ok, context}
      end
    end
  end
end
