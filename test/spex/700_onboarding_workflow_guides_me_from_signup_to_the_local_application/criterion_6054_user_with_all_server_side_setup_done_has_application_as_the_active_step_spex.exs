defmodule CodeMySpecSpex.Story700.Criterion6054Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6054 — Rule: Exactly one step is in the active state at
  a time — it is always the first incomplete step in the fixed order.

  A user with everything server-side done (account + project + a CLI
  has connected at least once) has the application rung as the
  active focal element. The dashboard's job ends there; the user's
  next click navigates them to the local workspace.

  Setup mirrors story 698's first-connect contract: drive the
  CliChannel join through Phoenix.ChannelTest so users.cli_first_connected_at
  is stamped through the real surface.
  """

  use CodeMySpecSpex.Case
  use Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Application is the unique active step once server-side setup is done" do
    scenario "User with all server-side setup done has application as the active step" do
      given_ "the user has had a CLI join Presence at some point", context do
        {:ok, _reply, channel_socket} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
          |> subscribe_and_join(
            CodeMySpecWeb.CliChannel,
            "cli:user:#{context.user.id}",
            %{}
          )

        wait_for_channel(channel_socket)
        {:ok, context}
      end

      given_ "the user mounts /app", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the application rung is the active focal element", context do
        assert has_element?(
                 context.view,
                 "[data-test='application-rung'][data-state='active']"
               ),
               "expected application-rung in 'active' state once everything before it is done"

        {:ok, context}
      end

      then_ "the account, project, and plugin rungs are in their done state", context do
        for rung <- ~w(account-rung project-rung plugin-rung) do
          assert has_element?(context.view, "[data-test='#{rung}'][data-state='done']"),
                 "expected #{rung} in 'done' state"
        end

        {:ok, context}
      end

      then_ "no other rung is in the active state", context do
        for rung <- ~w(account-rung project-rung plugin-rung) do
          refute has_element?(context.view, "[data-test='#{rung}'][data-state='active']"),
                 "did not expect #{rung} in 'active' state — only application should be active"
        end

        # Anchor: application IS active.
        assert has_element?(
                 context.view,
                 "[data-test='application-rung'][data-state='active']"
               )

        {:ok, context}
      end
    end
  end
end
