defmodule CodeMySpecSpex.Story815.Criterion6577Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6577 — Cross-user access is denied.

  Rule: An end-user only sees their own conversation, never another
  end-user's.

  Surface (forward-looking — red until built):
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — a
      socket authenticated as user B must not be able to join user A's topic
      "conversation:<A>". The join is rejected with {:error, _}.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @user_a "end-user-6577-a"
  @user_a_email "alice@example.com"
  @user_b "end-user-6577-b"
  @user_b_email "bob@example.com"

  spex "A user cannot access another user's conversation" do
    scenario "Cross-user access is denied" do
      given_ "a conversation belongs to user A", context do
        {:ok, _reply, chan_a} =
          CodeMySpecWeb.WidgetSocket
          |> socket("widget:#{@user_a}", %{
            project_id: context.project.id,
            end_user_id: @user_a,
            end_user_email: @user_a_email
          })
          |> subscribe_and_join(
            CodeMySpecWeb.ConversationChannel,
            "conversation:#{@user_a}",
            %{}
          )

        Phoenix.ChannelTest.push(chan_a, "send_message", %{"body" => "Private to Alice"})
        wait_for_channel(chan_a)

        {:ok, context}
      end

      when_ "user B attempts to access user A's conversation", context do
        join_result =
          CodeMySpecWeb.WidgetSocket
          |> socket("widget:#{@user_b}", %{
            project_id: context.project.id,
            end_user_id: @user_b,
            end_user_email: @user_b_email
          })
          |> subscribe_and_join(
            CodeMySpecWeb.ConversationChannel,
            "conversation:#{@user_a}",
            %{}
          )

        {:ok, Map.put(context, :join_result, join_result)}
      end

      then_ "access is denied", context do
        assert {:error, _reason} = context.join_result,
               "expected user B's join of user A's conversation to be rejected, got: #{inspect(context.join_result)}"

        {:ok, context}
      end
    end
  end
end
