defmodule CodeMySpecSpex.Story984.Criterion8172Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8172 — A sub-agent's work is distinguishable from its parent's.

  Two turns arrive from the sprite — one from the main agent, one from a QA
  sub-agent — and the operator must be able to tell them apart. A conversation
  where the sub-agent's turns merge into its parent's reads as one confused
  agent.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sub-agent turns are attributed to the sub-agent" do
    scenario "A sub-agent's work is distinguishable from its parent's" do
      given_ "the main agent has taken a turn", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("plan the next requirement"),
          Fixtures.model_response([Fixtures.text_block("Starting with the spec.")]),
          agent_role: "main"
        )

        {:ok, context}
      end

      when_ "a QA sub-agent takes a turn of its own", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("verify the login page"),
          Fixtures.model_response([Fixtures.text_block("The page renders.")]),
          agent_role: "qa"
        )

        {:ok, context}
      end

      then_ "the sub-agent's turn is marked as the sub-agent's", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(view, "[data-test='message'][data-agent-role='qa']"),
               "expected the QA sub-agent's turn to carry its agent role"

        {:ok, context}
      end

      and_ "the main agent's turn is not attributed to the sub-agent", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(view, "[data-test='message']:not([data-agent-role='qa'])"),
               "expected the main agent's turn to remain distinct from the sub-agent's"

        {:ok, context}
      end
    end
  end
end
