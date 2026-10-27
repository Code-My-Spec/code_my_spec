defmodule CodeMySpecSpex.Story559.Criterion168Spex do
  @moduledoc """
  Story 559 — Three Amigos.
  Criterion 168 — Sealing waits until every rule has a scenario.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "the story cannot be sealed while a rule is unmet", criterion: 168 do
    scenario "the open rule blocks sealing, then coverage lets the graph advance" do
      given_ :persona_exists

      given_ "three rules exist and the third has no scenario", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        assigns = Map.put(frame.assigns, :scope, frame.assigns[:current_scope])

        for n <- 1..3 do
          rule_response =
            ToolLibrary.run(
              "add_rule",
              %{story_number: context.story.number, statement: "Project summary rule #{n}"},
              assigns
            )

          assert match?({:ok, _}, rule_response)
        end

        for n <- 1..2 do
          scenario_response =
            ToolLibrary.run(
              "add_scenario",
              %{
                story_number: context.story.number,
                rule_statement: "Project summary rule #{n}",
                title: "Sam sees rule #{n} applied",
                kind: "happy_path",
                body:
                  "Given Sam opens a project\nWhen the summary loads\nThen rule #{n} is applied"
              },
              assigns
            )

          assert match?({:ok, _}, scenario_response)
        end

        {:ok, context}
      end

      given_ :three_amigos_task_started

      when_ "the agent evaluates the story with an uncovered rule", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :first_evaluation, response)}
      end

      then_ "the unmet rule prevents the seal", context do
        assert response_text(context.first_evaluation) =~
                 ~r/needs work|uncovered|missing|scenario/i,
               "expected the uncovered rule to block Three Amigos readiness"

        {:ok, context}
      end

      when_ "the agent covers the last rule and evaluates again", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        assigns = Map.put(frame.assigns, :scope, frame.assigns[:current_scope])

        scenario_response =
          ToolLibrary.run(
            "add_scenario",
            %{
              story_number: context.story.number,
              rule_statement: "Project summary rule 3",
              title: "Sam sees rule 3 applied",
              kind: "happy_path",
              body: "Given Sam opens a project\nWhen the summary loads\nThen rule 3 is applied"
            },
            assigns
          )

        assert match?({:ok, _}, scenario_response)

        evaluation =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            assigns
          )

        {:ok, Map.put(context, :final_evaluation, evaluation)}
      end

      then_ "the seal succeeds and discovery advances beyond this story's Three Amigos task",
            context do
        assert response_text(context.final_evaluation) =~ ~r/passed|complete/i,
               "expected all three covered rules to pass readiness"

        frame = %Frame{assigns: %{current_scope: context.scope}}

        next_response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        body = response_text(next_response)

        refute body =~ "three_amigos_complete" and body =~ to_string(context.story.id),
               "expected discovery to advance after the story was sealed"

        {:ok, context}
      end
    end
  end
end
