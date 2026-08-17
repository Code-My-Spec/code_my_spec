defmodule CodeMySpecSpex.Story815.Criterion6575Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6575 — Teammate reads and replies.

  Rule: Any CMS user in the account can read and reply to a user's
  conversation.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — a
      user starts a conversation with the account.
    * `CodeMySpecWeb.InboxLive` — a *second* CMS user in the same account opens
      the conversation from `/app/inbox`, sees it, and replies in the
      `/app/inbox/:id` thread via form [data-test='message-form'].
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @end_user_id "end-user-6575"
  @end_user_email "needshelp@example.com"

  spex "Any teammate in the account can read and reply" do
    scenario "Teammate reads and replies" do
      given_ "a user started a conversation and a teammate shares the account", context do
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

        Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "Need a hand here please"})
        wait_for_channel(channel)

        teammate = Fixtures.user_fixture()
        _member = Fixtures.member_fixture(teammate, context.account, :member)
        teammate_scope = Fixtures.user_scope_fixture(teammate, context.account)
        Fixtures.select_active_account(teammate_scope, context.account.id)
        teammate_conn = log_in_user(build_conn(), teammate)

        {:ok, Map.merge(context, %{channel: channel, teammate_conn: teammate_conn})}
      end

      when_ "the teammate opens the conversation and replies", context do
        {:ok, index_view, _html} =
          live(context.teammate_conn, "/app/projects/#{context.project.id}/inbox")

        {:ok, show_view, thread_html} =
          index_view
          |> element("[data-test='conversation']")
          |> render_click()
          |> follow_redirect(context.teammate_conn)

        show_view
        |> form("[data-test='message-form']", message: %{body: "On it — let me take a look"})
        |> render_submit()

        {:ok, Map.merge(context, %{show_view: show_view, thread_html: thread_html})}
      end

      then_ "the teammate saw the conversation and their reply is in the thread", context do
        assert context.thread_html =~ "Need a hand here please",
               "expected the teammate to see the conversation the user started"

        assert render(context.show_view) =~ "On it — let me take a look",
               "expected the teammate's reply to land in the same thread"

        {:ok, context}
      end
    end
  end
end
