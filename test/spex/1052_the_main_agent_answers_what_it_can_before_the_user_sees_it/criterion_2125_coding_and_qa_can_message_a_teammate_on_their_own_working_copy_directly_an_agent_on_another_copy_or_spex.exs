defmodule CodeMySpecSpex.Story1052.Criterion2125Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2125 — Coding and QA can message a teammate on their own working
  copy directly; an agent on another copy, or main or product, is reached
  through a question, not a message.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import CodeMySpecSpex.WorkingCopyHelpers, only: [join_working_copy: 3]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.MessageAgent
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    Fixtures.use_recording_transport(context)
  end

  spex "A coding agent messages a teammate on its own working copy directly", criterion: 2125 do
    scenario "a coding agent messages a QA agent on its own working copy" do
      given_ "a coding agent and a QA agent joined on the same working copy", context do
        {:ok, main_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "the main checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        {:ok, _} = WorkingCopies.designate_main(context.scope, main_copy.id)

        reply = join_working_copy(context, "/tmp/spex-2125-own-copy", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        coder =
          Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2125-own-copy")

        qa = Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-2125-own-copy")

        {:ok,
         Map.merge(context, %{
           qa_id: qa.id,
           coder_frame: %Frame{assigns: %{current_scope: scope, agent_id: coder.id}}
         })}
      end

      when_ "the coding agent messages the QA agent directly", context do
        params = %{agent_id: context.qa_id, message: "Can you re-run the spex for this one?"}
        {:reply, reply, _frame} = MessageAgent.execute(params, context.coder_frame)
        {:ok, Map.put(context, :message_reply, reply)}
      end

      then_ "it is delivered", context do
        refute context.message_reply.isError,
               "a teammate on the same working copy refused a direct message:\n" <>
                 response_text(context.message_reply)

        {:ok, context}
      end
    end
  end

  spex "Reaching the main agent goes through a question, not a message", criterion: 2125 do
    scenario "a coding agent tries to message the main agent directly" do
      given_ "a coding agent and a main agent on the same working copy", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           coder_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
         })}
      end

      when_ "the coding agent tries to message the main agent directly", context do
        params = %{agent_id: context.main_id, message: "Can you take a look at this?"}
        {:reply, reply, _frame} = MessageAgent.execute(params, context.coder_frame)
        {:ok, Map.put(context, :message_reply, reply)}
      end

      then_ "it is refused, and told to ask instead", context do
        assert context.message_reply.isError,
               "messaging the main agent directly was allowed, with no question in the way"

        assert response_text(context.message_reply) =~ ~r/ask_user_question/i,
               """
               The refusal did not point at `ask_user_question` as the way to \
               reach the main agent.

               #{response_text(context.message_reply)}
               """

        {:ok, context}
      end
    end
  end

  spex "Reaching an agent on another working copy goes through a question, not a message",
    criterion: 2125 do
    scenario "a coding agent tries to message a QA agent on another working copy" do
      given_ "a coding agent, and a QA agent on a different working copy", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {:ok, other_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "another checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        other_scope = %{context.scope | active_working_copy_id: other_copy.id}
        other_qa = Fixtures.running_agent(other_scope, role: "qa", continuous: true)

        {:ok,
         Map.merge(context, %{
           other_qa_id: other_qa.id,
           coder_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
         })}
      end

      when_ "the coding agent tries to message that QA agent", context do
        params = %{agent_id: context.other_qa_id, message: "Can you take a look at this?"}
        {:reply, reply, _frame} = MessageAgent.execute(params, context.coder_frame)
        {:ok, Map.put(context, :message_reply, reply)}
      end

      then_ "it is refused, and told to ask instead", context do
        assert context.message_reply.isError,
               "messaging an agent on another working copy was allowed, with no question in the way"

        assert response_text(context.message_reply) =~ ~r/ask_user_question/i,
               """
               The refusal did not point at `ask_user_question` as the way to \
               reach an agent on another working copy.

               #{response_text(context.message_reply)}
               """

        {:ok, context}
      end
    end
  end
end
