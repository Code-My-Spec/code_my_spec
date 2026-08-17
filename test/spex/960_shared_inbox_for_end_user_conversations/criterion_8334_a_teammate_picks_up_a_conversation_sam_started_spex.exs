defmodule CodeMySpecSpex.Story960.Criterion8334Spex do
  @moduledoc """
  Story 960 — Shared inbox for end-user conversations.
  Criterion 8334 — A teammate picks up a conversation Sam started.

  Rule: Any user in the account can read and reply.

  Support does not belong to whoever answered first. If a thread is only
  legible to the person who touched it, cover is impossible and the visitor
  waits for one specific human to come back.

  Surface: `CodeMySpecWeb.InboxLive` at `/app/projects/:project_id/inbox`, with
  the visitor's half driven over `CodeMySpecWeb.ConversationChannel` — the two
  ends of one conversation, which is the only way to prove a reply arrives.
  """

  use CodeMySpecSpex.Case

  # The spex Case imports Plug.Conn and Phoenix.LiveViewTest, which export their
  # own push/3 and assert_reply/3. The channel's are qualified at the call site.
  import Phoenix.ChannelTest, except: [push: 3, assert_reply: 3]

  alias CodeMySpecSpex.Fixtures

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

  spex "A conversation belongs to the account, not to whoever answered" do
    scenario "A teammate picks up a conversation Sam started" do
      given_ "Sam replied to a visitor earlier", context do
        {:ok, _, socket} = join_widget(context.project.id, "eu-team", "team@example.com")
        ref = Phoenix.ChannelTest.push(socket, "send_message", %{"body" => "my invoice is wrong"})
        Phoenix.ChannelTest.assert_reply(ref, :ok, _, 1000)

        {:ok, inbox, _html} = live(context.conn, inbox_path(context.project))
        result = inbox |> element("[data-test='conversation']") |> render_click()
        {:ok, thread, _html} = follow_redirect(result, context.conn)

        thread
        |> form("[data-test='message-form']", %{message: %{body: "on it, one moment"}})
        |> render_submit()

        {:ok, context}
      end

      when_ "a teammate on the same account opens that conversation", context do
        teammate = Fixtures.user_fixture()
        Fixtures.member_fixture(teammate, context.account, :member)
        mate_conn = log_in_user(build_conn(), teammate)

        {:ok, inbox, _html} = live(mate_conn, inbox_path(context.project))
        result = inbox |> element("[data-test='conversation']") |> render_click()
        {:ok, thread, html} = follow_redirect(result, mate_conn)

        {:ok, Map.merge(context, %{mate_thread: thread, mate_html: html, mate_conn: mate_conn})}
      end

      then_ "they can read the whole thread including Sam's reply", context do
        assert context.mate_html =~ "my invoice is wrong",
               "expected the visitor's message"

        assert context.mate_html =~ "on it, one moment",
               "expected Sam's reply to be readable by the teammate"

        {:ok, context}
      end

      then_ "they can reply to it themselves", context do
        html =
          context.mate_thread
          |> form("[data-test='message-form']", %{message: %{body: "picking this up"}})
          |> render_submit()

        assert html =~ "picking this up",
               "expected the teammate's reply to land on the thread"

        {:ok, context}
      end
    end
  end
end
