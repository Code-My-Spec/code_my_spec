defmodule CodeMySpecWeb.HarnessChannelTest do
  @moduledoc """
  The user-plane side of the harness bridge: an `agent_message` relayed from the
  local app is persisted onto the session's conversation (rendered in the operator
  inbox), and an operator reply is pushed back down to the harness as
  `user_message` tagged with the session's external id.

  Also `agents_running`, the report of what the box is actually running. A copy
  runs one or more lanes and the reconcile keys on the lane's role — before it
  did, the second lane on a checkout overwrote the first and the page showed one
  row flickering between two engines.
  """

  # Sync, and this one has a reason: the channel runs in its own process, so an
  # async sandbox connection checked out by the test is not one the channel can
  # see. It passes alone either way — the failure only appears under
  # concurrency, which is why "it passed when I flipped it" is not evidence.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.WorkingCopies

  @endpoint CodeMySpecWeb.Endpoint

  @external_id "pi:/tmp/harness-server-test"

  setup do
    scope = full_scope_fixture()

    # A real working copy, issued the way a checkout gets one. The report keys
    # on this id, so a test that invents a uuid would be testing a shape rather
    # than the join.
    {:ok, harness} =
      WorkingCopies.issue(scope, nil,
        label: "the harness at /tmp/two-lanes",
        device: device_fixture(scope)
      )

    {:ok, harness} = WorkingCopies.report_root(harness, "/tmp/two-lanes")

    {:ok, _reply, channel} =
      CodeMySpecWeb.UserSocket
      |> socket("user_socket:#{scope.user.id}", %{scope: scope})
      |> subscribe_and_join(
        CodeMySpecWeb.HarnessChannel,
        "harness:#{scope.active_account_id}",
        %{}
      )

    %{scope: scope, channel: channel, harness: harness}
  end

  test "two lanes on one working copy are two agents, not one", %{
    scope: scope,
    channel: channel,
    harness: harness
  } do
    ref =
      push(channel, "agents_running", %{
        "agents" => [
          lane(harness, "coding"),
          lane(harness, "qa")
        ]
      })

    assert_reply ref, :ok, %{"running" => running}, 5_000
    assert length(running) == 2

    roles = scope |> Agents.list_running() |> Enum.map(& &1.role) |> Enum.sort()

    assert roles == [:coding, :qa],
           "a checkout runs one or more agents. Keying the reconcile on the copy " <>
             "alone made the second lane overwrite the first, so two agents " <>
             "working side by side rendered as one row changing its mind."
  end

  test "a lane that stops being reported stops being running, and its sibling does not",
       %{scope: scope, channel: channel, harness: harness} do
    push(channel, "agents_running", %{
      "agents" => [lane(harness, "coding"), lane(harness, "qa")]
    })

    ref = push(channel, "agents_running", %{"agents" => [lane(harness, "coding")]})

    assert_reply ref, :ok, %{"running" => _}, 5_000

    assert scope |> Agents.list_running() |> Enum.map(& &1.role) == [:coding],
           "the report is the whole set, so a lane it omits has stopped — but " <>
             "only that lane. Reaping by working copy would take the sibling " <>
             "that is still working with it."
  end

  # One lane on that copy, the way `LaneReporter` composes it. `working_copy_id` is
  # the key; `working_copy` rides along because the path is real and the
  # conversation is keyed from it.
  defp lane(harness, role) do
    %{
      "harness_id" => harness.id,
      "working_copy" => harness.root,
      "role" => role,
      "provider" => "zai"
    }
  end

  test "a reported agent naming no working copy is refused, not guessed at", %{
    scope: scope,
    channel: channel
  } do
    ref =
      push(channel, "agents_running", %{
        "agents" => [%{"working_copy" => "/tmp/two-lanes", "role" => "coding"}]
      })

    assert_reply ref, :ok, %{"running" => running}, 5_000

    assert running == [],
           "a report with no working_copy_id used to be matched against harnesses.root, " <>
             "which is another reported string. Guessing produces an agent attached " <>
             "to whichever copy happened to match, and on this project five roots " <>
             "name more than one harness."

    assert Agents.list_running(scope) == []
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
      Conversations.find_or_create_session_conversation(
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
      Conversations.find_or_create_session_conversation(
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
