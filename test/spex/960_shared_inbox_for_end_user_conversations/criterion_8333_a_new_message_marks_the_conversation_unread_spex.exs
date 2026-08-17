defmodule CodeMySpecSpex.Story960.Criterion8333Spex do
  @moduledoc """
  Story 960 — Shared inbox for end-user conversations.
  Criterion 8333 — A new message marks the conversation unread.

  Rule: A conversation nobody has read looks unread.

  An inbox that cannot say what is new is a list, and a list of everything is
  the same as no inbox at all.

  Surface: `CodeMySpecWeb.InboxLive` at `/app/projects/:project_id/inbox`, with
  the visitor's half driven over `CodeMySpecWeb.ConversationChannel` — the two
  ends of one conversation, which is the only way to prove a reply arrives.
  """

  use CodeMySpecSpex.Case

  # The spex Case imports Plug.Conn and Phoenix.LiveViewTest, which export their
  # own push/3 and assert_reply/3. The channel's are qualified at the call site.
  import Phoenix.ChannelTest, except: [push: 3, assert_reply: 3]

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp join_widget(project_id, end_user_id, email) do
    CodeMySpecWeb.WidgetSocket
    |> socket("widget:#{end_user_id}", %{
      project_id: project_id,
      end_user_id: end_user_id,
      end_user_email: email
    })
    |> subscribe_and_join(CodeMySpecWeb.ConversationChannel, "conversation:#{end_user_id}", %{})
  end

  defp inbox_path(project), do: "/app/projects/#{project.id}/inbox"

  spex "Unread is visible and clears on reading" do
    scenario "A new message marks the conversation unread" do
      given_ "a visitor sends a message Sam has not seen", context do
        {:ok, _, socket} = join_widget(context.project.id, "eu-unread", "unread@example.com")
        ref = Phoenix.ChannelTest.push(socket, "send_message", %{"body" => "anyone home?"})
        Phoenix.ChannelTest.assert_reply(ref, :ok, _, 1000)

        {:ok, context}
      end

      when_ "he opens the inbox list", context do
        {:ok, inbox, html} = live(context.conn, inbox_path(context.project))

        {:ok, Map.merge(context, %{inbox: inbox, html: html})}
      end

      then_ "that conversation is marked unread", context do
        assert has_element?(context.inbox, "[data-test='conversation'][data-unread='true']"),
               "expected the conversation to be marked unread in the list"

        {:ok, context}
      end

      then_ "opening it stops it being unread", context do
        result = context.inbox |> element("[data-test='conversation']") |> render_click()
        {:ok, _thread, _html} = follow_redirect(result, context.conn)

        {:ok, reopened, _html} = live(context.conn, inbox_path(context.project))

        refute has_element?(reopened, "[data-test='conversation'][data-unread='true']"),
               "expected reading it to clear the unread mark"

        {:ok, context}
      end
    end
  end
end
