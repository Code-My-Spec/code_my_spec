defmodule CodeMySpecSpex.Story1024.Criterion2897Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2897 — Something I said mid-turn is not dropped.

  Rule: A message sent while the agent is busy is delivered when it settles,
  rather than lost.

  Mid-turn is when you are most likely to send something, because watching an
  agent work is what makes you want to redirect it. So "busy" cannot mean the
  message evaporates.

  `Alloy.send_message/3` answers `{:error, :busy}` upstream, which makes
  refusing the easy implementation and losing the message the easy accident.
  The PM's decision is that it waits: accepted, visibly pending, delivered when
  the turn ends.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Busy is not a reason to lose it" do
    scenario "Something I said mid-turn is not dropped" do
      given_ "an agent in the middle of a turn", context do
        copy = CodeMySpec.TempFile.dir("spex_2897")
        File.mkdir_p!(copy)

        agent = Fixtures.start_agent_for(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        Fixtures.agent_begins_turn(context.scope, agent)

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "I send it a message", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        html =
          live
          |> form("form[phx-submit=send_message]", %{"message" => "also update the README"})
          |> render_submit()

        {:ok, context |> Map.put(:html, html) |> Map.put(:conversation, conversation)}
      end

      then_ "the message is accepted and shown as waiting", context do
        assert context.html =~ ~r/waiting|queued|pending/i,
               "a message sent mid-turn shows no pending state, so the operator " <>
                 "cannot tell whether it was taken, refused, or dropped. Got: " <>
                 String.slice(context.html, 0, 300)

        {:ok, context}
      end

      then_ "and the agent acts on it once the current turn finishes", context do
        Fixtures.agent_finishes_turn(context.scope, context.agent)

        assert Fixtures.agent_received?(context.scope, context.agent, "also update the README"),
               "the turn ended and the queued message was never delivered. Refusing " <>
                 "while busy and forgetting are indistinguishable to whoever sent it, " <>
                 "and this is the moment an operator is most likely to be redirecting " <>
                 "the agent."

        {:ok, context}
      end
    end
  end
end
