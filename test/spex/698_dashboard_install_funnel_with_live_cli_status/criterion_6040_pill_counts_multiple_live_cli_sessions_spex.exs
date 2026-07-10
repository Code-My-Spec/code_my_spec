defmodule CodeMySpecSpex.Story698.Criterion6040Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6040 — Rule: Concurrent CLI sessions are counted, not
  collapsed.

  Setup: register a user, join two distinct CLI channels under the
  same user (different socket ids, simulating two machines), mount
  /app, assert the pill displays "Connected (2 sessions)".
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  # The pill lives on the plugin rung, which needs the earlier rungs done —
  # the ladder needs an active project (pill renders on both the active
  # install panel and the collapsed Done tile).
  setup :setup_active_project

  spex "Pill reflects the live CLI session count" do
    scenario "Pill counts multiple live CLI sessions" do
      given_ "two CLI sessions are connected for the user", context do
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

        {:ok, Map.merge(context, %{sock_a: sock_a, sock_b: sock_b})}
      end

      when_ "the user loads the dashboard", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the pill displays Connected with a count of 2 sessions", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "Connected",
               "expected the pill to read Connected with two sessions, got: #{pill}"

        assert pill =~ "2 sessions",
               "expected the pill to show 2 sessions, got: #{pill}"

        {:ok, context}
      end
    end
  end
end
