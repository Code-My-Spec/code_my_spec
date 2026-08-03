defmodule CodeMySpecSpex.Story815.Criterion6573Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6573 — Live delivery while connected.

  Rule: A message is delivered in real time when the recipient is connected.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.InboxLive` — the operator has the conversation thread
      (`/app/inbox/:id`) open and connected.
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — a
      connected user pushes "send_message". The open thread must re-render the
      new message over its own PubSub without a reload.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @end_user_id "end-user-6573"
  @end_user_email "live@example.com"

  spex "A message is delivered live while the operator has the thread open" do
    scenario "Live delivery while connected" do
      given_ "the operator has the conversation thread open and the user is connected", context do
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

        # An opening message so the conversation exists to open in the inbox.
        Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "Knock knock"})
        wait_for_channel(channel)

        {:ok, index_view, _html} = live(context.conn, "/app/projects/#{context.project.id}/inbox")

        {:ok, show_view, _html} =
          index_view
          |> element("[data-test='conversation']")
          |> render_click()
          |> follow_redirect(context.conn)

        {:ok, Map.merge(context, %{show_view: show_view, channel: channel})}
      end

      when_ "the connected user sends another message", context do
        Phoenix.ChannelTest.push(context.channel, "send_message", %{"body" => "Are you there?"})
        wait_for_channel(context.channel)
        {:ok, context}
      end

      then_ "the operator sees it appear in the open thread without refreshing", context do
        assert render(context.show_view) =~ "Are you there?",
               "expected the live message to appear in the open thread without a reload"

        {:ok, context}
      end
    end
  end
end
