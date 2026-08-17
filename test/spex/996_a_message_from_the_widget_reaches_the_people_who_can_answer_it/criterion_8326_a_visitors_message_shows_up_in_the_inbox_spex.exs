defmodule CodeMySpecSpex.Story996.Criterion8326Spex do
  @moduledoc """
  Story 996 — A message from the widget reaches the people who can answer it.
  Criterion 8326 — A visitors message shows up in the inbox.

  Rule: A message sent from the widget reaches the operator.

  The whole point of the widget. A message that is accepted, stored and never
  surfaced to anyone who could answer it is the same as one that was dropped —
  worse, because the visitor believes they have been heard.

  Surface: `CodeMySpecWeb.ConversationChannel` over `CodeMySpecWeb.WidgetSocket`
  — the socket the widget on a customer's site actually joins. Driven as the
  widget drives it, because that is the only public surface the end-user half
  has.
  """

  use CodeMySpecSpex.Case

  # The spex Case imports Plug.Conn and Phoenix.LiveViewTest, which export
  # their own push/3 and assert_reply/3. The channel's are qualified at the
  # call site rather than shadowing either.
  import Phoenix.ChannelTest, except: [push: 3, assert_reply: 3]

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Exactly how the widget joins: an end-user identified on the socket, its own
  # topic, no CMS user scope anywhere.
  defp join_widget(project_id, end_user_id, email) do
    CodeMySpecWeb.WidgetSocket
    |> socket("widget:#{end_user_id}", %{
      project_id: project_id,
      end_user_id: end_user_id,
      end_user_email: email
    })
    |> subscribe_and_join(CodeMySpecWeb.ConversationChannel, "conversation:#{end_user_id}", %{})
  end

  spex "A message from the widget reaches someone who can answer" do
    scenario "A visitor's message shows up in the inbox" do
      given_ "a visitor has the widget open on Sam's site", context do
        {:ok, _, socket} =
          join_widget(context.project.id, "eu-visitor", "visitor@example.com")

        {:ok, Map.put(context, :socket, socket)}
      end

      when_ "they send a message", context do
        ref =
          Phoenix.ChannelTest.push(context.socket, "send_message", %{
            "body" => "my booking page is broken"
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _, 1000)

        {:ok, context}
      end

      then_ "it appears on the conversation the operator inbox lists", context do
        {:ok, inbox, html} =
          live(context.conn, "/app/projects/#{context.project.id}/inbox")

        assert html =~ "my booking page is broken",
               "expected the visitor's message to be visible to the operator"

        assert has_element?(inbox, "[data-test='conversation-row']") or
                 html =~ "visitor@example.com",
               "expected the conversation to be listed against the visitor"

        {:ok, context}
      end

      then_ "it is attributed to that visitor, not to Sam", context do
        {:ok, _inbox, html} =
          live(context.conn, "/app/projects/#{context.project.id}/inbox")

        assert html =~ "visitor@example.com",
               "expected the visitor named as the author, got: #{html}"

        {:ok, context}
      end
    end
  end
end
