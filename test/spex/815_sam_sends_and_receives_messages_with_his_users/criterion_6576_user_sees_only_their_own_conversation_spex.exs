defmodule CodeMySpecSpex.Story815.Criterion6576Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6576 — User sees only their own conversation.

  Rule: An end-user only sees their own conversation, never another
  end-user's.

  Surface (forward-looking — red until built):
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — each
      end-user joins their own topic "conversation:<end_user_id>". On join the
      server replays only that user's history as "new_message"; another user's
      messages must never arrive.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @user_a "end-user-6576-a"
  @user_a_email "alice@example.com"
  @user_b "end-user-6576-b"
  @user_b_email "bob@example.com"

  spex "An end-user sees only their own conversation" do
    scenario "User sees only their own conversation" do
      given_ "two different users each have their own conversation", context do
        join_and_send(context, @user_a, @user_a_email, "Message meant for Alice only")
        join_and_send(context, @user_b, @user_b_email, "Message meant for Bob only")

        # Await + discard both seed echoes (delivered to the test process
        # asynchronously) so only Alice's fresh-join replay is under assertion
        # below. Deterministic, unlike draining the mailbox once.
        assert_receive %Phoenix.Socket.Message{event: "new_message"}, 1000
        assert_receive %Phoenix.Socket.Message{event: "new_message"}, 1000

        {:ok, context}
      end

      when_ "user Alice opens her widget afresh", context do
        {:ok, _reply, channel} =
          CodeMySpecWeb.WidgetSocket
          |> socket("widget:#{@user_a}-2", %{
            project_id: context.project.id,
            end_user_id: @user_a,
            end_user_email: @user_a_email
          })
          |> subscribe_and_join(
            CodeMySpecWeb.ConversationChannel,
            "conversation:#{@user_a}",
            %{}
          )

        {:ok, Map.put(context, :channel, channel)}
      end

      then_ "she sees only her own messages, never the other user's", context do
        assert_push "new_message", %{body: "Message meant for Alice only"}
        refute_push "new_message", %{body: "Message meant for Bob only"}, 100

        {:ok, context}
      end
    end
  end

  defp join_and_send(context, end_user_id, end_user_email, body) do
    {:ok, _reply, channel} =
      CodeMySpecWeb.WidgetSocket
      |> socket("widget:#{end_user_id}", %{
        project_id: context.project.id,
        end_user_id: end_user_id,
        end_user_email: end_user_email
      })
      |> subscribe_and_join(
        CodeMySpecWeb.ConversationChannel,
        "conversation:#{end_user_id}",
        %{}
      )

    Phoenix.ChannelTest.push(channel, "send_message", %{"body" => body})
    wait_for_channel(channel)
    channel
  end
end
