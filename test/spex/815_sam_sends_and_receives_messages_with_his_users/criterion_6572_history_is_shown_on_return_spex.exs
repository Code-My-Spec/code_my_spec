defmodule CodeMySpecSpex.Story815.Criterion6572Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6572 — History is shown on return.

  Rule: Conversation history is persisted and visible to both parties.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — the
      user sends several messages over time.
    * `CodeMySpecWeb.InboxLive` — when the operator opens the conversation from
      the inbox list, the `/app/inbox/:id` thread renders the full history in
      chronological order.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @end_user_id "end-user-6572"
  @end_user_email "returning@example.com"

  spex "Conversation history is shown when the operator opens the thread" do
    scenario "History is shown on return" do
      given_ "a conversation already has prior messages", context do
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

        Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "Question one"})
        Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "Question two"})
        wait_for_channel(channel)

        {:ok, Map.put(context, :channel, channel)}
      end

      when_ "the operator opens the conversation later", context do
        {:ok, index_view, _html} = live(context.conn, "/app/inbox")

        {:ok, _show_view, html} =
          index_view
          |> element("[data-test='conversation']")
          |> render_click()
          |> follow_redirect(context.conn)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "all prior messages are shown in order", context do
        html = context.html

        assert html =~ "Question one", "expected the first message in the history"
        assert html =~ "Question two", "expected the second message in the history"

        first = html |> :binary.match("Question one") |> elem(0)
        second = html |> :binary.match("Question two") |> elem(0)

        assert first < second,
               "expected messages rendered in chronological order (one before two)"

        {:ok, context}
      end
    end
  end
end
