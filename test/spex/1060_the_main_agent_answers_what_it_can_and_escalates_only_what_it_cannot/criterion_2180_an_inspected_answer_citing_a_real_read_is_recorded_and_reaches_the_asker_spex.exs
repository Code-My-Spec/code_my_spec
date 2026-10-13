defmodule CodeMySpecSpex.Story1060.Criterion2180Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 2180 — `answer_notification` accepts basis `inspected` with a
  citation of what the answerer read: file paths, commits, or the tool calls
  it made and what they returned. The answer is recorded, reaches the asker
  and releases its task.

  Issue da5a5ebf: `record` and `precedent` are the only two bases, and
  neither covers an answer grounded in main's own review of the repository or
  project state read through its own tools — so that whole class of
  legitimately-grounded answers could not be recorded. The citation is
  checked against reads the answerer actually made in its own session
  (criterion 2181 is the refusal when it is not).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Conversations
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An inspected answer citing a real read is recorded and reaches the asker",
       criterion: 2180 do
    scenario "the main agent answers from a file it actually read this session" do
      given_ "a coding agent's question, and a main agent that already read the file it answers from",
             context do
        reply = join_working_copy(context, "/tmp/spex-2180", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-2180-main")
        coder = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2180")

        {:ok, conversation} =
          Conversations.find_or_create_agent_conversation(
            scope.active_account_id,
            scope.active_project_id,
            main.id
          )

        {:ok, _call} =
          Conversations.add_tool_call(
            conversation,
            "call-1",
            "read",
            %{"path" => "config/dev.exs"},
            "main"
          )

        {:ok, _result} =
          Conversations.add_tool_result(conversation, "call-1", "read", "port: 4004",
            agent_role: "main"
          )

        asking = %Frame{assigns: %{current_scope: scope, agent_id: coder.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "which port is dev on",
              questions: [
                %{"question" => "Which port does dev listen on?", "options" => []}
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:coder, coder)
         |> Map.put(:main_frame, %Frame{assigns: %{current_scope: scope, agent_id: main.id}})
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent answers with basis inspected, citing the file it read", context do
        {:reply, answered, _frame} =
          AnswerNotification.execute(
            %{
              notification_id: context.question_id,
              answer: "4004 — set explicitly in config/dev.exs",
              basis: "inspected",
              citation: "config/dev.exs"
            },
            context.main_frame
          )

        {:ok, Map.put(context, :answered, answered)}
      end

      then_ "it is recorded and reaches the asker", context do
        refute context.answered.isError,
               """
               An answer citing a file the main agent actually read this session was
               refused as unrecorded.

               reply:
               #{response_text(context.answered)}
               """

        asker_frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.coder.id}
        }

        {:reply, checked, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, asker_frame)

        assert response_text(checked) =~ "4004",
               """
               The asking agent was never told the answer.

               reply:
               #{response_text(checked)}
               """

        {:ok, context}
      end

      then_ "and the user is not asked", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               A question the main agent could answer from its own reading still
               reached the user.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
