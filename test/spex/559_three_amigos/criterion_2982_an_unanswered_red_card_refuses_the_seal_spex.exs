defmodule CodeMySpecSpex.Story559.Criterion1061Spex do
  @moduledoc """
  Story 559 — Three Amigos.
  Criterion 1061 — An unanswered question prevents sealing.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "an unanswered red card refuses the Three Amigos seal", criterion: 1061 do
    scenario "evaluation names the open question and points to resolve_question" do
      given_ :persona_exists

      given_ "a rule has two scenarios and one question remains open", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        assigns = Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        statement = "Suspended cards cannot be used for purchases"

        assert {:ok, _} =
                 ToolLibrary.run(
                   "add_rule",
                   %{story_number: context.story.number, statement: statement},
                   assigns
                 )

        for {title, kind, outcome} <- [
              {"Suspended card purchase is declined", "happy_path", "the purchase is declined"},
              {"Card status cannot be loaded", "failure_path",
               "the purchase is declined for safety"}
            ] do
          assert {:ok, _} =
                   ToolLibrary.run(
                     "add_scenario",
                     %{
                       story_number: context.story.number,
                       rule_statement: statement,
                       title: title,
                       kind: kind,
                       body:
                         "Given Sam attempts a purchase\nWhen the card is checked\nThen #{outcome}"
                     },
                     assigns
                   )
        end

        question = "Does a mid-transaction suspension apply immediately?"

        assert {:ok, _} =
                 ToolLibrary.run(
                   "add_question",
                   %{story_number: context.story.number, text: question},
                   assigns
                 )

        {:ok, Map.put(context, :open_question, question)}
      end

      given_ :three_amigos_task_started

      when_ "the agent evaluates the Three Amigos task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the story remains unsealed and the response identifies the red card", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work|invalid|open question|unanswered/i,
               "expected the open question to block the seal"

        assert body =~ context.open_question,
               "expected the response to name the unanswered question"

        assert body =~ "resolve_question",
               "expected the response to explain how to resolve the red card"

        frame = %Frame{assigns: %{current_scope: context.scope}}

        requirements =
          ToolLibrary.run(
            "list_requirements",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert {:ok, _} = requirements

        assert response_text(requirements) =~
                 ~r/\[ \]\s+\*\*three_amigos_complete\*\*/,
               "expected Three Amigos to remain unsatisfied while the question is open"

        {:ok, context}
      end
    end
  end
end
