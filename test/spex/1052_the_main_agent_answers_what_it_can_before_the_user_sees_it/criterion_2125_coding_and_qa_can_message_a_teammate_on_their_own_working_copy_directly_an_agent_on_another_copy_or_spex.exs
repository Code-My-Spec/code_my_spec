defmodule CodeMySpecSpex.Story1052.Criterion2125Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2125 — Coding and QA can message a teammate on their own working
  copy directly; an agent on another copy, or product, is reached through a
  question, not a message.

  Issue 0ae29c2a (2026-10-19): main is no longer on that "reached through a
  question" list. John's decision: message_agent reaches main from any copy,
  by id or by role. The criterion's own recorded text still names main
  alongside product -- flagged to product to bring up to date; this spex
  asserts the behavior as decided, not as the stale text still reads.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import CodeMySpecSpex.WorkingCopyHelpers, only: [join_working_copy: 3]

  alias Anubis.Server.Frame
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

        reply =
          ToolLibrary.run(
            "message_agent",
            params,
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns.current_scope
            )
          )

        {:ok, Map.put(context, :message_reply, reply)}
      end

      then_ "it is delivered", context do
        assert match?({:ok, _}, context.message_reply),
               "a teammate on the same working copy refused a direct message:\n" <>
                 response_text(context.message_reply)

        {:ok, context}
      end
    end
  end

  spex "Reaching the main agent happens directly, not through a question", criterion: 2125 do
    scenario "a coding agent messages the main agent directly" do
      given_ "a coding agent and a main agent on the same working copy", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           coder_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
         })}
      end

      when_ "the coding agent messages the main agent directly", context do
        params = %{agent_id: context.main_id, message: "Can you take a look at this?"}

        reply =
          ToolLibrary.run(
            "message_agent",
            params,
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns.current_scope
            )
          )

        {:ok, Map.put(context, :message_reply, reply)}
      end

      then_ "it is delivered", context do
        assert match?({:ok, _}, context.message_reply),
               "main was supposed to be reachable directly (issue 0ae29c2a):\n" <>
                 response_text(context.message_reply)

        {:ok, context}
      end
    end

    scenario "a coding agent messages the main agent from a different working copy" do
      given_ "a coding agent on one copy and the main agent on another", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {:ok, other_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "main's checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        other_scope = %{context.scope | active_working_copy_id: other_copy.id}
        main = Fixtures.running_agent(other_scope, role: "main", continuous: true)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           coder_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
         })}
      end

      when_ "the coding agent messages the main agent directly", context do
        params = %{agent_id: context.main_id, message: "Can you take a look at this?"}

        reply =
          ToolLibrary.run(
            "message_agent",
            params,
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns.current_scope
            )
          )

        {:ok, Map.put(context, :message_reply, reply)}
      end

      then_ "it is delivered, same copy or not", context do
        assert match?({:ok, _}, context.message_reply),
               "main was supposed to be reachable from any copy (issue 0ae29c2a):\n" <>
                 response_text(context.message_reply)

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

        reply =
          ToolLibrary.run(
            "message_agent",
            params,
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns.current_scope
            )
          )

        {:ok, Map.put(context, :message_reply, reply)}
      end

      then_ "it is refused, and told to ask instead", context do
        assert match?({:error, _}, context.message_reply),
               "messaging an agent on another working copy was allowed, with no question in the way"

        assert response_text(context.message_reply) =~ ~r/ask_question/i,
               """
               The refusal did not point at `ask_question` as the way to \
               reach an agent on another working copy.

               #{response_text(context.message_reply)}
               """

        {:ok, context}
      end
    end
  end
end
