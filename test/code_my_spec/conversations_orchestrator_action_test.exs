defmodule CodeMySpec.ConversationsOrchestratorActionTest do
  @moduledoc """
  What the orchestrator did, on the agent's own thread.

  Story 985. The transcript recorded what the *agent* did and nothing the
  harness did to it, so a conversation that changed direction between one turn
  and the next carried no explanation — the reason lived in a log on another
  machine.

  These cover the record; the spex under `test/spex/1041_*` cover what a reader
  sees. Both are needed: an action written and not rendered is as invisible as
  one never written.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message

  setup do
    scope = full_scope_fixture()

    {:ok, agent} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        engine: :pi,
        provider: "anthropic",
        working_copy: "/workspace/app",
        role: "coding",
        working_copy_id: scope.active_working_copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running
      })

    {:ok, _conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{scope: scope, agent: agent}
  end

  defp parts(message), do: message.content

  defp part(message, type) do
    Enum.find_value(parts(message), fn
      %{"type" => ^type, "text" => text} -> text
      _ -> nil
    end)
  end

  test "an action lands on the agent's conversation as its own kind", %{agent: agent} do
    assert {:ok, message} =
             Conversations.record_orchestrator_action(agent, "Stopped you: compile failed.")

    assert message.role == :orchestrator,
           "recorded as #{message.role}. The agent did not do this, and any role that " <>
             "says it did makes a reader draw a conclusion about the agent's judgement " <>
             "from the orchestrator's act."

    assert part(message, "text") == "Stopped you: compile failed."
  end

  test "a count and a tool ride as their own parts", %{agent: agent} do
    assert {:ok, message} =
             Conversations.record_orchestrator_action(agent, "Stopped you.",
               count: "3 problems",
               tool: "list_problems"
             )

    assert part(message, "count") == "3 problems",
           "the count is baked into the sentence, so a reader has to parse prose for a " <>
             "number and the view cannot render it distinctly."

    assert part(message, "tool") == "list_problems",
           "an action that summarises without saying how to get the rest asks the reader " <>
             "to take it on trust, which is the opposite of what a count is for."
  end

  test "an action with nothing to quantify carries no empty parts", %{agent: agent} do
    assert {:ok, message} =
             Conversations.record_orchestrator_action(agent, "Gave you the next requirement.")

    assert part(message, "count") == nil
    assert part(message, "tool") == nil

    assert length(parts(message)) == 1,
           "handing over a requirement has no quantity, and a blank count renders as a " <>
             "number that means nothing."
  end

  test "an agent with no conversation is not an error", %{scope: scope} do
    {:ok, unwatched} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        engine: :pi,
        provider: "anthropic",
        working_copy: "/workspace/unwatched",
        role: "coding",
        working_copy_id: scope.active_working_copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running
      })

    assert :ok = Conversations.record_orchestrator_action(unwatched, "Stopped you."),
           "recording failed for an agent nobody is watching. An orchestrator acting on " <>
             "one is not an error, and a recorder that can fail here makes writing the " <>
             "note able to fail the act it is describing."
  end

  test "no agent at all is not an error" do
    assert :ok = Conversations.record_orchestrator_action(nil, "Stopped you.")
  end

  test "the action is in the transcript's own stream", %{scope: scope, agent: agent} do
    {:ok, _} = Conversations.record_orchestrator_action(agent, "Stopped you.")

    conversation = Repo.get_by(Conversations.Conversation, agent_id: agent.id)
    messages = Conversations.list_messages(conversation)

    assert Enum.any?(messages, &(&1.role == :orchestrator)),
           "the action was written somewhere `list_messages/1` does not read, so it " <>
             "cannot sit next to the turn it explains — which is the whole reason it is " <>
             "a message rather than a table of its own."

    assert %Message{} = Enum.find(messages, &(&1.role == :orchestrator))
    _ = scope
  end
end
