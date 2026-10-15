defmodule CodeMySpecSpex.Story1023.Criterion2208Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 2208 — I fire an agent from its conversation: the agent
  conversation page has the same Fire action for the agent it shows.

  No scenario was recorded against this criterion; this one is a mechanical
  translation of its title. An operator watching an agent's own conversation
  should not have to navigate back to the working copy page to fire it —
  the same action belongs here too.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent conversation page carries the same Fire action", criterion: 2208 do
    scenario "I fire an agent from its conversation" do
      given_ "an agent whose conversation I am looking at", context do
        agent = Fixtures.running_agent(context.scope)
        start_agent(agent.id, working_copy: agent.working_copy)
        conversation = Fixtures.agent_conversation(context.scope, agent)

        {:ok, view, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation?#{[conversation: conversation.id]}"
          )

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:view, view)
         |> Map.put(:html, html)}
      end

      when_ "I look for its Fire action", context do
        {:ok, context}
      end

      then_ "the same Fire action is here for the agent it shows", context do
        assert has_element?(context.view, "[data-test='fire-agent']"),
               "the conversation page for this agent has no Fire action — firing it " <>
                 "requires navigating back to the working copy page instead"

        {:ok, context}
      end

      then_ "and using it retires the agent the conversation belongs to", context do
        context.view
        |> element("[data-test='fire-agent']")
        |> render_click()

        context.view
        |> element("[data-test='confirm-fire-agent']")
        |> render_click()

        refute running?(context.agent.id),
               "firing from the conversation page did not end the agent's process it shows"

        {:ok, context}
      end
    end
  end
end
