defmodule CodeMySpec.Conversations.MessageTest do
  @moduledoc """
  A turn carrying only tool calls is a normal agent turn, not an empty one.

  `name_an_empty_writer/1` used to check `content` alone, so `add_tool_call/5`
  — content: [], tool_calls: [...] — tripped the same "an empty message
  reached the changeset" warning meant for a writer that produced nothing at
  all. Measured at 1,620 occurrences in one day, carrying no signal: it fired
  on turns that succeeded exactly as often as ones that failed, and made
  web.log unreadable during an incident.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import ExUnit.CaptureLog

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations

  setup do
    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        working_copy: "/workspace/app",
        role: "coding",
        working_copy_id: scope.active_working_copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{conversation: conversation}
  end

  test "a tool-call-only turn does not warn", %{conversation: conversation} do
    log =
      capture_log(fn ->
        assert {:ok, _message} =
                 Conversations.add_tool_call(conversation, "call-1", "list_stories", %{})
      end)

    refute log =~ "an empty message reached the changeset"
  end

  test "a turn with neither content nor tool calls still warns", %{conversation: conversation} do
    log =
      capture_log(fn ->
        %CodeMySpec.Conversations.Message{}
        |> CodeMySpec.Conversations.Message.agent_changeset(%{
          role: :assistant,
          conversation_id: conversation.id,
          sender_id: "agent:product",
          content: []
        })
        |> CodeMySpec.Repo.insert()
      end)

    assert log =~ "an empty message reached the changeset"
  end
end
