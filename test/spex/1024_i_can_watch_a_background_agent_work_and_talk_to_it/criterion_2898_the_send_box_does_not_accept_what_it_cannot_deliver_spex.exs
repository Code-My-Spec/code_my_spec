defmodule CodeMySpecSpex.Story1024.Criterion2898Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2898 — The send box does not accept what it cannot deliver.

  Rule: A control that cannot do the thing does not offer to.

  Not a hypothetical failure — the one this build already has. The send box is
  gated on a running agent for the working copy, accepts what you type, records
  it with `Conversations.add_message(:operator, ...)`, and delivers nothing.

  A control that silently does nothing is worse than a missing one. Missing,
  you go and find another way. Present and quiet, you believe the agent was
  told.

  This is the same failure QA found on `stop_agent` and on `start_agent` in the
  same week — a surface reporting an outcome it did not achieve — which is why
  it is a rule here rather than a note.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A control that cannot deliver does not offer to" do
    scenario "The send box does not accept what it cannot deliver" do
      given_ "a conversation whose agent is not running", context do
        copy = CodeMySpec.TempFile.dir("spex_2898")
        File.mkdir_p!(copy)

        # Started through the real surface so the conversation is opened the way
        # the app opens it, then stopped — which is the ordinary state of any
        # agent that has finished.
        agent = Fixtures.start_agent_for(context.scope, working_copy: copy)
        {:ok, _stopped} = Fixtures.stop_agent(context.scope, agent)

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "I look at it", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        {:ok, live, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        {:ok,
         context
         |> Map.put(:live, live)
         |> Map.put(:html, html)
         |> Map.put(:conversation, conversation)}
      end

      then_ "there is no send box offering to message the agent", context do
        refute context.html =~ "phx-submit=\"send_message\"",
               "the page offers to send a message to an agent that is not running. " <>
                 "Whatever is typed there cannot reach anybody, and the operator has " <>
                 "no way to know that from looking at it."

        {:ok, context}
      end

      then_ "and nothing I do records a message as though it had been sent", context do
        before_count = length(Fixtures.conversation_messages(context.scope, context.conversation))

        # The event a submit would raise, sent directly — because a control that
        # is merely hidden is still reachable, and "no button" is not the same
        # promise as "no effect".
        Fixtures.attempt_send(context.live, "are you there")

        after_count = length(Fixtures.conversation_messages(context.scope, context.conversation))

        assert after_count == before_count,
               "the message was recorded even though no agent could receive it. " <>
                 "Hiding the control is not enough: the transcript now claims " <>
                 "something was said to an agent that was not there to hear it."

        {:ok, context}
      end
    end
  end
end
