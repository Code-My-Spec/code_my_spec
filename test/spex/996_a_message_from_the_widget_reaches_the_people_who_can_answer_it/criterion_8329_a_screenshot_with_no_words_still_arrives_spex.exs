defmodule CodeMySpecSpex.Story996.Criterion8329Spex do
  @moduledoc """
  Story 996 — A message from the widget reaches the people who can answer it.
  Criterion 8327 — One visitor cannot open anothers conversation.

  Rule: A message carrying only an attachment is still a message.

  A visitor who screenshots the broken page and types nothing has said the
  most useful thing they can. The old model gave that message an empty body,
  and an empty body is exactly what a dropped message looks like.

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

  alias CodeMySpec.Conversations

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

  spex "An attachment on its own is a message" do
    scenario "A screenshot with no words still arrives" do
      given_ "a visitor has the widget open", context do
        {:ok, _, socket} = join_widget(context.project.id, "eu-shot", "shot@example.com")

        # A key the browser would already have uploaded to. Requesting a
        # presigned URL is a different criterion; this one is about whether the
        # message survives having no words in it.
        key = "chat/#{context.project.id}/qa-shot/broken.png"

        {:ok, Map.merge(context, %{socket: socket, key: key})}
      end

      when_ "they send it with no words", context do
        Phoenix.ChannelTest.push(context.socket, "send_message", %{
          "body" => "",
          "attachments" => [
            %{
              "s3_key" => context.key,
              "filename" => "broken.png",
              "content_type" => "image/png",
              "size" => 100
            }
          ]
        })

        {:ok, context}
      end

      then_ "the message arrives carrying the attachment", context do
        assert_push("new_message", %{attachments: [attachment]})

        assert attachment.filename == "broken.png",
               "expected the screenshot to come back with the message"

        {:ok, context}
      end

      then_ "the inbox shows it as a message rather than as blank", context do
        {:ok, _inbox, html} = live(context.conn, "/app/projects/#{context.project.id}/inbox")

        assert html =~ "shot@example.com",
               "expected the conversation listed even with no text in it"

        {:ok, context}
      end
    end
  end
end
