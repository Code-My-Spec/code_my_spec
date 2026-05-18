defmodule CodeMySpecSpex.Story698.Criterion6041Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6041 — Rule: Concurrent CLI sessions are counted, not
  collapsed. Disconnecting one session while another is still live
  does not flip the pill to disconnected.

  Setup: two CLI sessions connected, /app mounted, pill shows
  Connected (2 sessions). Close one channel. Pill must read
  "Connected (1 session)" — not "Disconnected".
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "One CLI disconnect with another still live keeps the pill connected" do
    scenario "Disconnect of one session keeps pill connected with reduced count" do
      given_ "two CLI sessions are connected and /app is open", context do
        {:ok, _r1, sock_a} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}:a", %{user_id: context.user.id, device: "a"})
          |> subscribe_and_join(
            CodeMySpecWeb.CliChannel,
            "cli:user:#{context.user.id}",
            %{}
          )

        {:ok, _r2, sock_b} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}:b", %{user_id: context.user.id, device: "b"})
          |> subscribe_and_join(
            CodeMySpecWeb.CliChannel,
            "cli:user:#{context.user.id}",
            %{}
          )

        wait_for_channel(sock_a)
        wait_for_channel(sock_b)

        {:ok, view, _html} = live(context.conn, "/app")

        {:ok, Map.merge(context, %{view: view, sock_a: sock_a, sock_b: sock_b})}
      end

      then_ "the pill initially reads Connected with 2 sessions", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "2 sessions",
               "expected initial pill to show 2 sessions, got: #{pill}"

        {:ok, context}
      end

      when_ "one of the two CLI processes exits", context do
        Process.flag(:trap_exit, true)
        :ok = close(context.sock_a)
        {:ok, context}
      end

      then_ "the pill still reads Connected", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "Connected",
               "expected the pill to remain Connected with one session live, got: #{pill}"

        refute pill =~ "Disconnected",
               "did not expect the pill to flip to Disconnected while one CLI is still live"

        {:ok, context}
      end

      then_ "the session count drops to 1", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "1 session",
               "expected the pill to show 1 session after one disconnect, got: #{pill}"

        {:ok, context}
      end
    end
  end
end
