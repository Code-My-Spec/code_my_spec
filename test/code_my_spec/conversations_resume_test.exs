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

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = CodeMySpec.UsersFixtures.full_scope_fixture()

    copy_id = CodeMySpec.WorkingCopies.ensure_default(scope)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: "main",
        working_copy_id: copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running
      })

    AgentPresence.present(agent)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{conversation: conversation, scope: scope, agent: agent}
  end

  defp checkpoint_prefix(_conversation, false), do: []

  defp checkpoint_prefix(conversation, true) do
    anchor = said(conversation, "earlier")
    summary = [%{"role" => "user", "content" => "summary"}]

    {:ok, _} =
      Conversations.record_checkpoint(conversation, summary, through_message_id: anchor.id)

    summary
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
        |> Enum.map(&Message.text/1)

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

  defp checkpoint_prefix(_conversation, false), do: []

  defp checkpoint_prefix(conversation, true) do
    anchor = said(conversation, "earlier")
    summary = [%{"role" => "user", "content" => "summary"}]

    {:ok, _} =
      Conversations.record_checkpoint(conversation, summary, through_message_id: anchor.id)

    summary
  end

  describe "what is left out" do
    for checkpoint? <- [false, true] do
      @checkpoint? checkpoint?
      test "undelivered messages are excluded with checkpoint=#{checkpoint?}", %{
        conversation: conversation
      } do
        prefix = checkpoint_prefix(conversation, @checkpoint?)

        for delivery <- [:pending, :withdrawn, :failed, :delivered] do
          {:ok, _} =
            Conversations.add_message(
              conversation,
              :operator,
              Atom.to_string(delivery),
              "operator",
              [],
              delivery: delivery,
              delivery_ref: Ecto.UUID.generate()
            )
        end

        said(conversation, "legacy message")

        assert Conversations.resume_messages(conversation) ==
                 prefix ++
                   [
                     %{"role" => "user", "content" => "delivered"},
                     %{"role" => "user", "content" => "legacy message"}
                   ]
      end
    end
  end

  describe "what the agent did" do
    defp call(conversation, id, name, args) do
      {:ok, _} = Conversations.add_tool_call(conversation, id, name, args, "main")
    end

    defp returned(conversation, id, name, text, opts \\ []) do
      {:ok, _} =
        Conversations.add_tool_result(conversation, id, name, text, [agent_role: "main"] ++ opts)
    end

    test "every call comes back with what it returned", %{conversation: conversation} do
      said(conversation, "have a look at the pricing module")
      call(conversation, "call-1", "read_file", %{"path" => "pricing.ex"})
      returned(conversation, "call-1", "read_file", "defmodule Pricing")
      call(conversation, "call-2", "bash", %{"command" => "mix test"})
      returned(conversation, "call-2", "bash", "bash failed: 1 failure", failed?: true)
      answered(conversation, "it charges per seat")

      assert Conversations.resume_messages(conversation) == [
               %{"role" => "user", "content" => "have a look at the pricing module"},
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_use",
                     "id" => "call-1",
                     "name" => "read_file",
                     "input" => %{"path" => "pricing.ex"}
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "call-1",
                     "content" => "defmodule Pricing"
                   }
                 ]
               },
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_use",
                     "id" => "call-2",
                     "name" => "bash",
                     "input" => %{"command" => "mix test"}
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "call-2",
                     "content" => "bash failed: 1 failure",
                     "is_error" => true
                   }
                 ]
               },
               %{"role" => "assistant", "content" => "it charges per seat"}
             ],
             "a resumed agent that knows it made calls and not what they returned " <>
               "cannot carry on a turn, only start it again"
    end

    test "a call cut off before it returned is answered as unknown, then the carry-on follows",
         %{conversation: conversation} do
      said(conversation, "run the suite")

      {:ok, _} =
        Conversations.add_transcript_message(
          conversation,
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "Running it."},
              %{"type" => "tool_use", "id" => "call-1", "name" => "bash", "input" => %{}}
            ]
          },
          "main"
        )

      said(conversation, "The harness restarted part-way through your turn.")

      assert [_asked, assistant, %{"role" => "user", "content" => [result, carry_on]}] =
               Conversations.resume_messages(conversation)

      assert assistant["content"] |> Enum.map(& &1["type"]) == ["text", "tool_use"]
      assert result["tool_use_id"] == "call-1"
      assert result["content"] =~ "No result was recorded"

      assert carry_on == %{
               "type" => "text",
               "text" => "The harness restarted part-way through your turn."
             },
             "the answer to the cut call and what the agent was told next are one turn"
    end

    test "a checkpoint's calls and results come back as the agent held them",
         %{conversation: conversation} do
      anchor = said(conversation, "earlier")

      held = [
        %{"role" => "user", "content" => "summary"},
        %{
          "role" => "assistant",
          "content" => [%{"type" => "tool_use", "id" => "c", "name" => "read", "input" => %{}}]
        },
        %{
          "role" => "user",
          "content" => [%{"type" => "tool_result", "tool_use_id" => "c", "content" => "ok"}]
        }
      ]

      {:ok, _} =
        Conversations.record_checkpoint(conversation, held, through_message_id: anchor.id)

      assert Conversations.resume_messages(conversation) == held
    end
  end
end
