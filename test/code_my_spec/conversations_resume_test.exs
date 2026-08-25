defmodule CodeMySpec.ConversationsResumeTest do
  @moduledoc """
  What an agent is handed when it comes back to a conversation.

  Two halves, and the second is the one with teeth. The whole transcript while
  it is short enough to give a model; from the last compaction checkpoint
  onward once it is not — because a project's conversation runs for months and
  a checkpoint is the only thing standing between that and an agent that can no
  longer be started at all.

  The failure this rules out is silent by construction. An agent resumed from
  the wrong slice still answers, still writes to the right transcript, and is
  simply missing something it was told — which nobody notices until they rely
  on it.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Conversations

  setup do
    scope = CodeMySpec.UsersFixtures.full_scope_fixture()

    copy_id = CodeMySpec.WorkingCopies.ensure_default(scope)

    {:ok, agent} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: "main",
        working_copy_id: copy_id,
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

    %{conversation: conversation, scope: scope, agent: agent}
  end

  defp said(conversation, text) do
    {:ok, message} = Conversations.add_message(conversation, :operator, text, "operator")
    message
  end

  defp answered(conversation, text) do
    {:ok, message} = Conversations.add_agent_message(conversation, "main", "assistant", text)
    message
  end

  describe "with no checkpoint" do
    test "the whole conversation comes back, in order", %{conversation: conversation} do
      said(conversation, "remember the pricing rule")
      answered(conversation, "noted")
      said(conversation, "and the refund one")

      assert Conversations.resume_messages(conversation) == [
               %{"role" => "user", "content" => "remember the pricing rule"},
               %{"role" => "assistant", "content" => "noted"},
               %{"role" => "user", "content" => "and the refund one"}
             ]
    end

    test "an agent that has never spoken resumes with nothing", %{conversation: conversation} do
      assert Conversations.resume_messages(conversation) == []
    end
  end

  describe "with a checkpoint" do
    test "resuming is the summary plus what was said after it", %{conversation: conversation} do
      said(conversation, "the first thing, long ago")
      anchor = answered(conversation, "a hundred turns of working")

      {:ok, _checkpoint} =
        Conversations.record_checkpoint(
          conversation,
          [
            %{"role" => "user", "content" => "the first thing, long ago"},
            %{"role" => "user", "content" => "Previous analysis summary: we agreed X"}
          ],
          through_message_id: anchor.id,
          turn: 40
        )

      said(conversation, "and then this morning")

      assert Conversations.resume_messages(conversation) == [
               %{"role" => "user", "content" => "the first thing, long ago"},
               %{"role" => "user", "content" => "Previous analysis summary: we agreed X"},
               %{"role" => "user", "content" => "and then this morning"}
             ],
             "what came back is not the summary plus the tail. Handing back the " <>
               "conversation the summary already covers is the one outcome worse than " <>
               "losing it: the agent pays for it twice and eventually cannot start."
    end

    test "the newest checkpoint is the one that counts", %{conversation: conversation} do
      first = said(conversation, "old")

      {:ok, _} =
        Conversations.record_checkpoint(conversation, [%{"role" => "user", "content" => "sum 1"}],
          through_message_id: first.id
        )

      second = answered(conversation, "middle")

      {:ok, _} =
        Conversations.record_checkpoint(conversation, [%{"role" => "user", "content" => "sum 2"}],
          through_message_id: second.id
        )

      said(conversation, "new")

      assert Conversations.resume_messages(conversation) == [
               %{"role" => "user", "content" => "sum 2"},
               %{"role" => "user", "content" => "new"}
             ]
    end

    test "a checkpoint anchors itself at the last message when nobody says where",
         %{conversation: conversation} do
      said(conversation, "before")

      {:ok, checkpoint} =
        Conversations.record_checkpoint(conversation, [%{"role" => "user", "content" => "sum"}])

      said(conversation, "after")

      assert checkpoint.through_message_id,
             "a checkpoint with no anchor cannot say where the tail starts"

      assert Conversations.resume_messages(conversation) == [
               %{"role" => "user", "content" => "sum"},
               %{"role" => "user", "content" => "after"}
             ]
    end

    test "a checkpoint with nothing in it is refused", %{conversation: conversation} do
      assert {:error, changeset} = Conversations.record_checkpoint(conversation, [])

      assert errors_on(changeset).messages != [],
             "an empty checkpoint would silently resume the agent on an empty " <>
               "conversation, which is indistinguishable from a new one"
    end
  end

  describe "when the agent compacts" do
    test "the summary is kept as a checkpoint, not as something the agent said",
         %{conversation: conversation, scope: scope, agent: agent} do
      said(conversation, "the first thing")

      :ok =
        CodeMySpec.Agents.record_turn_event(scope, agent.id, %{
          "kind" => "compacted",
          "turn" => 12,
          "messages" => [
            %{"role" => "user", "content" => "the first thing"},
            %{"role" => "user", "content" => "Previous analysis summary: we agreed X"}
          ]
        })

      checkpoint = Conversations.latest_checkpoint(conversation)

      assert checkpoint, "the agent compacted and nothing recorded where it resumes from"
      assert checkpoint.turn == 12

      texts =
        conversation
        |> Conversations.list_messages()
        |> Enum.map(&CodeMySpec.Conversations.Message.text/1)

      assert texts == ["the first thing"],
             "the summary was written into the transcript. A person scrolling back would " <>
               "read a summary of their own conversation as something the agent said to " <>
               "them, and every renderer would need a clause to skip it."
    end

    test "resuming after it starts from the summary", %{
      conversation: conversation,
      scope: scope,
      agent: agent
    } do
      said(conversation, "a hundred turns ago")

      :ok =
        CodeMySpec.Agents.record_turn_event(scope, agent.id, %{
          "kind" => "compacted",
          "turn" => 12,
          "messages" => [%{"role" => "user", "content" => "Previous analysis summary: X"}]
        })

      said(conversation, "and this morning")

      assert Conversations.resume_messages(conversation) == [
               %{"role" => "user", "content" => "Previous analysis summary: X"},
               %{"role" => "user", "content" => "and this morning"}
             ]
    end
  end

  describe "what is left out" do
    test "the agent's working is not replayed as things that were said",
         %{conversation: conversation} do
      said(conversation, "have a look at the pricing module")

      {:ok, _call} =
        Conversations.add_tool_call(
          conversation,
          "call-1",
          "read_file",
          %{"path" => "pricing.ex"},
          "main"
        )

      {:ok, _result} =
        Conversations.add_tool_result(
          conversation,
          "call-1",
          "read_file",
          "defmodule Pricing",
          agent_role: "main"
        )

      answered(conversation, "it charges per seat")

      assert Conversations.resume_messages(conversation) == [
               %{"role" => "user", "content" => "have a look at the pricing module"},
               %{"role" => "assistant", "content" => "it charges per seat"}
             ],
             "a tool result describes a file at a path, and an agent being resumed " <>
               "may be in a different checkout by then — story 963 moves the main " <>
               "agent between checkouts on purpose."
    end
  end
end
