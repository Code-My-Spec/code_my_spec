defmodule CodeMySpecSpex.Story960.Criterion8335Spex do
  @moduledoc """
  Story 960 — Shared inbox for end-user conversations.
  Criterion 8335 — Two teammates reply and each is attributed.

  Rule: A reply records which teammate sent it.

  Visibility is account-wide; authorship is not. Anyone can answer, but the
  record has to say who did — otherwise the thread reads as one anonymous
  voice, and nobody can tell who already promised the visitor what.

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

  spex "Each reply says who sent it" do
    scenario "Two teammates reply and each is attributed" do
      given_ "a visitor has written in", context do
        {:ok, _, socket} = join_widget(context.project.id, "eu-attr", "attr@example.com")
        ref = Phoenix.ChannelTest.push(socket, "send_message", %{"body" => "still broken"})
        Phoenix.ChannelTest.assert_reply(ref, :ok, _)

        {:ok, context}
      end

      when_ "Sam and a teammate each reply", context do
        {:ok, inbox, _html} = live(context.conn, inbox_path(context.project))
        result = inbox |> element("[data-test='conversation']") |> render_click()
        {:ok, thread, _html} = follow_redirect(result, context.conn)

        thread
        |> form("[data-test='message-form']", %{message: %{body: "Sam here, looking"}})
        |> render_submit()

        teammate = Fixtures.user_fixture()
        Fixtures.member_fixture(teammate, context.account, :member)
        mate_conn = log_in_user(build_conn(), teammate)

        {:ok, mate_inbox, _html} = live(mate_conn, inbox_path(context.project))
        mate_result = mate_inbox |> element("[data-test='conversation']") |> render_click()
        {:ok, mate_thread, _html} = follow_redirect(mate_result, mate_conn)

        html =
          mate_thread
          |> form("[data-test='message-form']", %{message: %{body: "teammate here, taking over"}})
          |> render_submit()

        {:ok, Map.merge(context, %{html: html, teammate: teammate})}
      end

      then_ "each reply is attributed to the person who sent it", context do
        assert context.html =~ "Sam here, looking",
               "anchor: Sam's reply should still be on the thread"

        assert context.html =~ "teammate here, taking over",
               "expected the teammate's reply too"

        sam_id = to_string(context.user.id)
        mate_id = to_string(context.teammate.id)

        assert context.html =~ ~s(data-sender-id="#{sam_id}"),
               "expected Sam's reply to record him as its author"

        assert context.html =~ ~s(data-sender-id="#{mate_id}"),
               "expected the teammate's reply to record them, not the account"

        {:ok, context}
      end
    end
  end
end
