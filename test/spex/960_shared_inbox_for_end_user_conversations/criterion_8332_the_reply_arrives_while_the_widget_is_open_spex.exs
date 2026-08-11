defmodule CodeMySpecSpex.Story960.Criterion8332Spex do
  @moduledoc """
  Story 960 — Shared inbox for end-user conversations.
  Criterion 8332 — The reply arrives while the widget is open.

  Rule: A reply reaches the visitor without them reloading.

  A support chat where the answer only appears on refresh is a slower email.
  The visitor is sitting there watching.

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

  spex "A reply reaches the visitor live" do
    scenario "The reply arrives while the widget is open" do
      given_ "a visitor has the widget open and has written in", context do
        {:ok, _, socket} = join_widget(context.project.id, "eu-live", "live@example.com")
        ref = Phoenix.ChannelTest.push(socket, "send_message", %{"body" => "are you there?"})
        Phoenix.ChannelTest.assert_reply(ref, :ok, _)

        {:ok, Map.put(context, :socket, socket)}
      end

      when_ "Sam replies from the inbox", context do
        {:ok, inbox, _html} = live(context.conn, inbox_path(context.project))

        # open_conversation push_navigates to the thread, so the index view is
        # gone after the click — the redirect has to be followed to get the
        # view that owns the reply form.
        result = inbox |> element("[data-test='conversation']") |> render_click()
        {:ok, thread, _html} = follow_redirect(result, context.conn)

        thread
        |> form("[data-test='message-form']", %{message: %{body: "yes, looking now"}})
        |> render_submit()

        {:ok, Map.put(context, :thread, thread)}
      end

      then_ "the reply appears in the widget without a reload", context do
        assert_push("new_message", %{body: "yes, looking now"})

        {:ok, context}
      end
    end
  end
end
