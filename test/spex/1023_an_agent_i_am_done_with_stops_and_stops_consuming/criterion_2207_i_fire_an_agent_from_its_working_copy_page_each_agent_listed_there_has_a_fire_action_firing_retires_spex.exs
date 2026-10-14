defmodule CodeMySpecSpex.Story1023.Criterion2207Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 2207 — I fire an agent from its working copy page: each agent
  listed there has a Fire action. Firing retires it — it never runs again,
  its seat is freed, and its conversation stays readable.

  No scenario was recorded against this criterion; this one is a mechanical
  translation of its title. Each agent row on the working copy page gets a
  Fire action, and using it retires the agent rather than merely stopping it:
  a retired agent's seat is empty (a replacement can be staffed into it) and
  its conversation stays there to be read, unlike a stop which only ends the
  process.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each agent on the working copy page can be fired, and firing retires it",
    criterion: 2207 do
    scenario "I fire an agent from its working copy page" do
      given_ "an agent listed on its working copy page", context do
        agent = Fixtures.running_agent(context.scope)
        start_agent(agent.id, working_copy: agent.working_copy)

        {:ok, view, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
          )

        assert has_element?(view, "[data-agent-id='#{agent.id}'] [data-test='fire-agent']"),
               "the agent's row has no Fire action — nothing lists one to use"

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      when_ "I use its Fire action", context do
        context.view
        |> element("[data-agent-id='#{context.agent.id}'] [data-test='fire-agent']")
        |> render_click()

        context.view
        |> element("[data-agent-id='#{context.agent.id}'] [data-test='confirm-fire-agent']")
        |> render_click()

        {:ok, context}
      end

      then_ "the agent it fired never runs again", context do
        refute running?(context.agent.id),
               "firing an agent did not end its process — it can still run"

        {:ok, context}
      end

      then_ "its seat is freed", context do
        html = render(context.view)

        refute html =~ "data-agent-id=\"#{context.agent.id}\"",
               "a fired agent still occupies a seat on the page — its role should read " <>
                 "as empty, the way a retired agent's does"

        {:ok, context}
      end

      then_ "and its conversation stays readable", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        {:ok, _view, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation?#{[conversation: conversation.id]}"
          )

        assert html =~ context.agent.id or html =~ to_string(context.agent.role),
               "a fired agent's conversation no longer renders — it should stay readable " <>
                 "even though the agent that held it never runs again"

        {:ok, context}
      end
    end
  end
end
