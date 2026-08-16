defmodule CodeMySpecWeb.HarnessChannelTest do
  @moduledoc """
  The user-plane side of the harness bridge: an `agent_message` relayed from the
  local app is persisted onto the session's conversation (rendered in the operator
  inbox), and an operator reply is pushed back down to the harness as
  `user_message` tagged with the session's external id.
  """

  # Sync, and this one has a reason: the channel runs in its own process, so an
  # async sandbox connection checked out by the test is not one the channel can
  # see. It passes alone either way — the failure only appears under
  # concurrency, which is why "it passed when I flipped it" is not evidence.
  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message

  @endpoint CodeMySpecWeb.Endpoint

  @external_id "pi:/tmp/harness-server-test"

  setup do
    scope = full_scope_fixture()

    {:ok, _reply, channel} =
      CodeMySpecWeb.UserSocket
      |> socket("user_socket:#{scope.user.id}", %{scope: scope})
      |> subscribe_and_join(
        CodeMySpecWeb.HarnessChannel,
        "harness:#{scope.active_account_id}",
        %{}
      )

    %{scope: scope, channel: channel}
  end

  test "join is rejected when the account doesn't match the socket scope", %{scope: scope} do
    assert {:error, %{reason: "unauthorized"}} =
             CodeMySpecWeb.UserSocket
             |> socket("user_socket:#{scope.user.id}", %{scope: scope})
             |> subscribe_and_join(
               CodeMySpecWeb.HarnessChannel,
               "harness:#{Ecto.UUID.generate()}",
               %{}
             )
  end

  test "agent_message is persisted onto the session's conversation", %{
    scope: scope,
    channel: channel
  } do
    push(channel, "agent_message", %{
      "external_id" => @external_id,
      "project_id" => scope.active_project_id,
      "role" => "coding",
      "kind" => "assistant",
      "text" => "implemented the context"
    })

    # Let the async handle_in persist before we read back.
    _ = :sys.get_state(channel.channel_pid)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        @external_id
      )

    assert conversation.session_external_id == @external_id
    assert conversation.end_user_email == nil

    [message] = Conversations.list_messages(conversation)
    assert message.role == :assistant
    assert message.agent_role == "coding"
    assert Message.text(message) == "implemented the context"
  end

  test "an operator reply is pushed down to the harness as user_message", %{
    scope: scope,
    channel: channel
  } do
    # First agent_message subscribes the channel to the conversation topic.
    push(channel, "agent_message", %{
      "external_id" => @external_id,
      "project_id" => scope.active_project_id,
      "role" => "manager",
      "kind" => "status",
      "text" => "manager online"
    })

    _ = :sys.get_state(channel.channel_pid)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        @external_id
      )

    # Operator replies in the inbox — broadcasts on the conversation topic.
    {:ok, _} =
      Conversations.add_message(conversation, :operator, "try the other approach", "op-1")

    assert_push "user_message", %{
      "external_id" => @external_id,
      "text" => "try the other approach"
    }
  end
end
