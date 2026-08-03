defmodule CodeMySpecSpex.Story815.Criterion6578Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6578 — Online status reflects connection.

  Rule: The account can see which of its app's users are currently online.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — a
      user's presence is tracked via `CodeMySpecWeb.Presence` while their
      widget is connected.
    * `CodeMySpecWeb.InboxLive` at "/app/projects/:project_id/inbox" — each conversation shows the
      user's live online/offline status, updated over PubSub without a reload.
      Status text is "Online" / "Offline".
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @end_user_id "end-user-6578"
  @end_user_email "presence@example.com"

  spex "The account sees a user's live online status" do
    scenario "Online status reflects connection" do
      given_ "the operator has the inbox open and the user is connected", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/inbox")

        {:ok, _reply, channel} =
          CodeMySpecWeb.WidgetSocket
          |> socket("widget:#{@end_user_id}", %{
            project_id: context.project.id,
            end_user_id: @end_user_id,
            end_user_email: @end_user_email
          })
          |> subscribe_and_join(
            CodeMySpecWeb.ConversationChannel,
            "conversation:#{@end_user_id}",
            %{}
          )

        Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "Hello there"})
        wait_for_channel(channel)

        {:ok, Map.merge(context, %{view: view, channel: channel})}
      end

      then_ "the inbox shows the user as online", context do
        assert render(context.view) =~ "Online",
               "expected the connected user shown Online"

        {:ok, context}
      end

      when_ "the user disconnects their widget", context do
        pid = context.channel.channel_pid
        ref = Process.monitor(pid)
        # Unlink so the channel's {:shutdown, :left} exit doesn't take the test
        # process down with it; monitor so we can wait for the leave (and its
        # presence untrack) to finish before observing the inbox.
        Process.unlink(pid)
        leave(context.channel)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          2000 -> :ok
        end

        {:ok, context}
      end

      then_ "the inbox shows the user as offline", context do
        assert render(context.view) =~ "Offline",
               "expected the disconnected user shown Offline after presence leave"

        {:ok, context}
      end
    end
  end
end
