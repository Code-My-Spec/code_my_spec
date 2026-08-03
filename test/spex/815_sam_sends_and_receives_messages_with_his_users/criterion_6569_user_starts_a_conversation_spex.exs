defmodule CodeMySpecSpex.Story815.Criterion6569Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6569 — User starts a conversation.

  Rule: Either the account or a registered user can start a conversation
  between them.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.InboxLive` at "/app/projects/:project_id/inbox" — the operator's unified inbox.
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` on
      topic "conversation:<end_user_id>" — the deploy-key widget ingress. A
      registered user pushes "send_message" %{"body" => ...}; the server
      persists it, creating the conversation on first contact, and surfaces it
      in the operator inbox over PubSub.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @end_user_id "end-user-6569"
  @end_user_email "newcomer@example.com"

  spex "A registered user can start a conversation with the account" do
    scenario "User starts a conversation" do
      given_ "the account has the inbox open and the user has no conversation yet", context do
        {:ok, view, html} = live(context.conn, "/app/projects/#{context.project.id}/inbox")

        refute html =~ @end_user_email,
               "expected no existing conversation for the user before they message"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the user sends their first message from the widget", context do
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

        Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "Hi, I need help getting started"})
        wait_for_channel(channel)

        {:ok, Map.put(context, :channel, channel)}
      end

      then_ "a new conversation with that message appears in the account inbox", context do
        inbox = render(context.view)

        assert inbox =~ "Hi, I need help getting started",
               "expected the user's first message to appear in the inbox"

        assert inbox =~ @end_user_email,
               "expected the new conversation to be labelled with the user's email"

        {:ok, context}
      end
    end
  end
end
