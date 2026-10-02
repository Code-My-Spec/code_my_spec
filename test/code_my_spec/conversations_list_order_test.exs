defmodule CodeMySpec.ConversationsListOrderTest do
  @moduledoc """
  Chat lists put the conversation with the latest message on top.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo

  setup do
    %{scope: full_scope_fixture()}
  end

  # Pins a message's time so two inserts in one test can't tie.
  defp at(%Message{id: id}, seconds_ago) do
    time = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    Repo.update_all(from(m in Message, where: m.id == ^id), set: [inserted_at: time])
  end

  describe "list_conversations/1" do
    test "latest message first, regardless of creation order", %{scope: scope} do
      {:ok, older} =
        Conversations.find_or_create_conversation(
          scope.active_account_id,
          scope.active_project_id,
          "first@example.com"
        )

      {:ok, newer} =
        Conversations.find_or_create_conversation(
          scope.active_account_id,
          scope.active_project_id,
          "second@example.com"
        )

      {:ok, m1} = Conversations.add_message(newer, :user, "early")
      at(m1, 3600)
      {:ok, m2} = Conversations.add_message(older, :user, "late")
      at(m2, 10)

      assert Enum.map(Conversations.list_conversations(scope), & &1.id) == [older.id, newer.id]
    end
  end

  describe "list_agent_conversations/2" do
    test "latest message first; a rename does not move a row", %{scope: scope} do
      {:ok, quiet} =
        Conversations.find_or_create_session_conversation(
          scope.active_account_id,
          scope.active_project_id,
          "pi:/tmp/quiet"
        )

      {:ok, busy} =
        Conversations.find_or_create_session_conversation(
          scope.active_account_id,
          scope.active_project_id,
          "pi:/tmp/busy"
        )

      {:ok, m1} = Conversations.add_agent_message(quiet, nil, "assistant", "a while ago")
      at(m1, 3600)
      {:ok, m2} = Conversations.add_agent_message(busy, nil, "assistant", "just now")
      at(m2, 10)

      {:ok, _} = Conversations.rename_agent_conversation(scope, quiet.id, "renamed")

      ids =
        scope
        |> Conversations.list_agent_conversations(scope.active_project_id)
        |> Enum.map(& &1.conversation.id)

      assert ids == [busy.id, quiet.id]
    end
  end
end
