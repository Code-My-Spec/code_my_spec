defmodule CodeMySpecSpex.Story815.Criterion6570Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6570 — Account starts a conversation.

  Rule: Either the account or a registered user can start a conversation
  between them.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.InboxLive` — the operator composes a new conversation
      addressed to a registered user by email via
      form [data-test='new-conversation-form'], landing in the new
      conversation's `/app/inbox/:id` thread.
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — when
      the user connects, the server pushes the operator's queued message as
      "new_message", so the user receives it.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @end_user_id "end-user-6570"
  @end_user_email "reachme@example.com"

  spex "The account can start a conversation with a registered user" do
    scenario "Account starts a conversation" do
      given_ "the account has the inbox open", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/inbox")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "a CMS user composes a message to the user", context do
        {:ok, show_view, _html} =
          context.view
          |> form("[data-test='new-conversation-form']",
            conversation: %{
              email: @end_user_email,
              body: "Hi! Thanks for signing up — anything I can help with?"
            }
          )
          |> render_submit()
          |> follow_redirect(context.conn)

        {:ok, Map.put(context, :show_view, show_view)}
      end

      then_ "the new thread holds the message and the user receives it on connect", context do
        thread = render(context.show_view)

        assert thread =~ @end_user_email,
               "expected the new conversation labelled with the user's email"

        assert thread =~ "Thanks for signing up",
               "expected the operator's opening message in the thread"

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

        assert_push "new_message", %{body: body}

        assert body =~ "Thanks for signing up",
               "expected the user to receive the operator's message on connect"

        {:ok, Map.put(context, :channel, channel)}
      end
    end
  end
end
