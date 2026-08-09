defmodule CodeMySpecSpex.Story996.Criterion8328Spex do
  @moduledoc """
  Story 996 — A message from the widget reaches the people who can answer it.
  Criterion 8327 — One visitor cannot open anothers conversation.

  Rule: Coming back to the widget shows what was already said.

  The channel replays history on join, and nothing has asserted it. A visitor
  who comes back to an empty box assumes their message was lost and writes it
  again — which is how one problem becomes three conversations.

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

  spex "The conversation is waiting when a visitor comes back" do
    scenario "A returning visitor sees the thread so far" do
      given_ "a visitor sent a message earlier and Sam replied", context do
        {:ok, _, socket} = join_widget(context.project.id, "eu-return", "return@example.com")

        ref =
          Phoenix.ChannelTest.push(socket, "send_message", %{"body" => "is the calendar broken?"})

        Phoenix.ChannelTest.assert_reply(ref, :ok, _)

        conversation = Conversations.get_agent_conversation(context.scope, context.project.id)
        {:ok, Map.put(context, :first_socket, socket)}
      end

      when_ "they open the widget again", context do
        {:ok, _, returned} = join_widget(context.project.id, "eu-return", "return@example.com")

        {:ok, Map.put(context, :returned, returned)}
      end

      then_ "what they said before is replayed to them", context do
        assert_receive %Phoenix.Socket.Message{
                         topic: "conversation:eu-return",
                         event: "new_message",
                         payload: %{body: "is the calendar broken?"}
                       },
                       500

        {:ok, context}
      end
    end
  end
end
