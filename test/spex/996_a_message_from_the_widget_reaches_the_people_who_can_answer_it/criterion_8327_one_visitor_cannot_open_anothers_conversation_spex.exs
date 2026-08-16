defmodule CodeMySpecSpex.Story996.Criterion8327Spex do
  @moduledoc """
  Story 996 — A message from the widget reaches the people who can answer it.
  Criterion 8327 — One visitor cannot open anothers conversation.

  Rule: An end-user only ever sees their own conversation.

  The channel's own moduledoc states this — "joining another user's
  conversation is rejected (end-user isolation)" — and nothing has ever
  asserted it. It is the difference between a support widget and a way to read
  other people's support threads, and it was protected only by prose.

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

  spex "A visitor is isolated to their own conversation" do
    scenario "One visitor cannot open another's conversation" do
      given_ "two visitors have each been talking to Sam", context do
        {:ok, _, first} = join_widget(context.project.id, "eu-first", "first@example.com")

        ref =
          Phoenix.ChannelTest.push(first, "send_message", %{
            "body" => "first visitor's private problem"
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _)

        {:ok, Map.put(context, :first, first)}
      end

      when_ "one tries to join the other's conversation", context do
        result =
          CodeMySpecWeb.WidgetSocket
          |> socket("widget:eu-second", %{
            project_id: context.project.id,
            end_user_id: "eu-second",
            end_user_email: "second@example.com"
          })
          |> subscribe_and_join(CodeMySpecWeb.ConversationChannel, "conversation:eu-first", %{})

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the join is refused", context do
        assert {:error, _} = context.result,
               "expected joining another end-user's topic to be refused, got: #{inspect(context.result)}"

        {:ok, context}
      end

      then_ "nothing from the other conversation is sent to them", context do
        # Joining their own topic is allowed, and is where a leak would show:
        # history is replayed on join, so if isolation were broken the first
        # visitor's message would arrive here. Refuting on the first visitor's
        # topic would only catch that visitor's own echo — the test process is
        # subscribed to it.
        {:ok, _, _second} =
          join_widget(context.project.id, "eu-second", "second@example.com")

        # Named by topic, not just by body: the test process is still subscribed
        # to the first visitor's topic from the given_, and that visitor's own
        # message is legitimately sitting in the mailbox. What must never
        # happen is it arriving on the second visitor's topic.
        refute_receive %Phoenix.Socket.Message{
                         topic: "conversation:eu-second",
                         event: "new_message",
                         payload: %{body: "first visitor's private problem"}
                       },
                       200

        {:ok, context}
      end
    end
  end
end
