defmodule CodeMySpecSpex.Story815.Criterion6574Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6574 — Delivery on next connect.

  Rule: A message sent while the recipient is offline is delivered when they
  next connect.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.InboxLive` at "/app/projects/:project_id/inbox" — the operator sends a message
      to a user who is not currently connected.
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — when
      the user later connects, the server pushes the stored message as
      "new_message".
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @end_user_id "end-user-6574"
  @end_user_email "offline@example.com"

  spex "A message sent to an offline user is delivered on next connect" do
    scenario "Delivery on next connect" do
      given_ "the user is offline", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/inbox")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the account sends them a message while they are offline", context do
        context.view
        |> form("[data-test='new-conversation-form']",
          conversation: %{
            email: @end_user_email,
            body: "Following up on your question from earlier"
          }
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the user receives the stored message the next time they connect", context do
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

        assert body =~ "Following up on your question",
               "expected the offline message delivered on the user's next connect"

        {:ok, Map.put(context, :channel, channel)}
      end
    end
  end
end
