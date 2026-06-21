defmodule CodeMySpecSpex.Story815.Criterion6571Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6571 — Replies append to the same thread.

  Rule: Messages between a user and the account stay in one continuous thread
  per user.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — the
      user opens the thread by sending the first message.
    * `CodeMySpecWeb.InboxLive` — the operator opens the conversation from the
      `/app/inbox` list and replies in its `/app/inbox/:id` thread via
      form [data-test='message-form']. The reply appends to the same thread.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @end_user_id "end-user-6571"
  @end_user_email "regular@example.com"

  spex "Replies stay in one continuous thread per user" do
    scenario "Replies append to the same thread" do
      given_ "a user has an open conversation with the account", context do
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

        Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "First message from me"})
        wait_for_channel(channel)

        {:ok, index_view, _html} = live(context.conn, "/app/inbox")

        {:ok, show_view, _html} =
          index_view
          |> element("[data-test='conversation']")
          |> render_click()
          |> follow_redirect(context.conn)

        {:ok, Map.merge(context, %{show_view: show_view, channel: channel})}
      end

      when_ "the account replies in that conversation", context do
        context.show_view
        |> form("[data-test='message-form']", message: %{body: "Happy to help — what's up?"})
        |> render_submit()

        {:ok, context}
      end

      then_ "both the user's message and the reply sit in the one thread", context do
        thread = render(context.show_view)

        assert thread =~ "First message from me",
               "expected the user's original message in the thread"

        assert thread =~ "Happy to help",
               "expected the account's reply appended to the same thread"

        {:ok, context}
      end
    end
  end
end
