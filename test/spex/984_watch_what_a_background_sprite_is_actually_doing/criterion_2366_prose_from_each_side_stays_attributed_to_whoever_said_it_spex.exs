defmodule CodeMySpecSpex.Story984.Criterion2366Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2366 — Prose from each side stays attributed to whoever said it.

  The guard on the rest of this rule. Telling results and calls apart is worth
  nothing if the fix swallows ordinary conversation with them — an operator's
  own instruction rendered as a tool result would be the same defect pointing
  the other way.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Ordinary conversation survives the sorting" do
    scenario "Prose from each side stays attributed to whoever said it" do
      when_ "the operator asks something and the agent answers", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("why did the suite go red"),
          Fixtures.model_response([
            %{"type" => "text", "text" => "A migration had not been run."}
          ])
        )

        {:ok, context}
      end

      then_ "the agent's words render as the agent's", context do
        {:ok, view, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert has_element?(view, "[data-test='message'][data-role='assistant']")
        assert html =~ "A migration had not been run."

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the operator's words render as the operator's", context do
        assert has_element?(context.view, "[data-test='message'][data-role='user']")
        assert context.html =~ "why did the suite go red"

        {:ok, context}
      end

      then_ "neither is mistaken for a call or a result", context do
        refute has_element?(context.view, "[data-test='tool-call']"),
               "no tool was called in this turn"

        refute has_element?(context.view, "[data-test='tool-result']"),
               "sorting results out of user-role messages must not swallow real ones"

        {:ok, context}
      end
    end
  end
end
