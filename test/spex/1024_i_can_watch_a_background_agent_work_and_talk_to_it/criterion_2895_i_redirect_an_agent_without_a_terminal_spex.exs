defmodule CodeMySpecSpex.Story1024.Criterion2895Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2895 — I redirect an agent without a terminal.

  Rule: A message I send reaches the agent.

  The half that is missing outright. The view has a send box already, gated on
  a running agent for the copy, and submitting it calls
  `Conversations.add_message(:operator, ...)` and stops there. The message is
  recorded and never delivered.

  That was correct under the previous design — a Pi lane collected operator
  messages when it settled, through the stop hook. Nothing does that now, so
  the box is live and goes nowhere.

  `Agents.message_agent/4` is the delivery: server to harness to
  `Engine.chat/3`, verified against a real agent that wrote a file and
  answered. What this criterion asks for is the view using it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Talking to an agent from where you watch it" do
    scenario "I redirect an agent without a terminal" do
      given_ "an agent running on my working copy", context do
        copy = CodeMySpec.TempFile.dir("spex_2895")
        File.mkdir_p!(copy)

        agent = Fixtures.start_agent_for(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:copy, copy)}
      end

      when_ "I send it a message from its conversation", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        html =
          live
          |> form("form[phx-submit=send_message]", %{"message" => "say READY and nothing else"})
          |> render_submit()

        {:ok, context |> Map.put(:html, html) |> Map.put(:conversation, conversation)}
      end

      then_ "the agent receives it and acts on it", context do
        assert Fixtures.agent_received?(context.scope, context.agent, "say READY"),
               "the message was recorded in the conversation and never delivered. " <>
                 "That is the failure this criterion exists for: the send box looks " <>
                 "like it worked, the operator believes the agent was told, and the " <>
                 "agent carries on doing whatever it was doing."

        {:ok, context}
      end

      then_ "and its answer appears in the same conversation", context do
        messages = Fixtures.conversation_messages(context.scope, context.conversation)

        assert Enum.any?(messages, &(&1.role == :agent)),
               "the agent's answer went somewhere other than the conversation the " <>
                 "operator is watching, so the exchange reads as one-sided"

        {:ok, context}
      end
    end
  end
end
