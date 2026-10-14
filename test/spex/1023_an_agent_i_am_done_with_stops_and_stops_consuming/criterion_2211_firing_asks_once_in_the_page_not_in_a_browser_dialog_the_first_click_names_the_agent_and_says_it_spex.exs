defmodule CodeMySpecSpex.Story1023.Criterion2211Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 2211 — Firing asks once in the page, not in a browser dialog: the
  first click names the agent and says it cannot be undone; the second click
  fires.

  No scenario was recorded against this criterion; this one is a mechanical
  translation of its title. The confirmation lives in the page's own markup
  rather than a browser `confirm()` dialog — LiveViewTest cannot see into a
  native dialog, and a confirmation nobody but the browser can read is not
  one QA or a future spec can assert on either.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Firing confirms in the page, naming the agent, before it is final", criterion: 2211 do
    scenario "Firing asks once in the page, not in a browser dialog" do
      given_ "an agent listed on its working copy page", context do
        agent = Fixtures.running_agent(context.scope)
        start_agent(agent.id, working_copy: agent.working_copy)

        {:ok, view, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
          )

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:view, view)}
      end

      when_ "I click its Fire action once", context do
        html =
          context.view
          |> element("[data-agent-id='#{context.agent.id}'] [data-test='fire-agent']")
          |> render_click()

        {:ok, Map.put(context, :after_first_click, html)}
      end

      then_ "the first click names the agent and says it cannot be undone", context do
        html = context.after_first_click

        assert html =~ to_string(context.agent.role) or html =~ context.agent.id,
               "the confirmation does not name the agent being fired. Got: #{html}"

        assert html =~ ~r/cannot be undone|cannot undo|permanent/i,
               "the confirmation does not say firing cannot be undone. Got: #{html}"

        assert running?(context.agent.id),
               "one click already fired the agent — the first click should only ask, " <>
                 "not act"

        {:ok, context}
      end

      when_ "I click it a second time", context do
        context.view
        |> element("[data-agent-id='#{context.agent.id}'] [data-test='confirm-fire-agent']")
        |> render_click()

        {:ok, context}
      end

      then_ "it fires", context do
        refute running?(context.agent.id),
               "a second click on the armed Fire action did not end the agent's process"

        {:ok, context}
      end
    end
  end
end
