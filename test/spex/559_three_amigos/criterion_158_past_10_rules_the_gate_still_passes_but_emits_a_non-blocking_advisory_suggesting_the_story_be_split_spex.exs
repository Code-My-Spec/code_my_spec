defmodule CodeMySpecSpex.Story559.Criterion5891Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5891 — When a story has 10 or more rules, the readiness
  gate fails on the `rules < 10` clause and the failure detail
  instructs the PM to slice the story.

  Enforces the rules-ceiling clause from the readiness gate. The
  workshop heuristic from Example Mapping (Wynne) is that >8–10 rules
  means the story is too big to spec coherently in one session.

  Depends on:
    - `BddRulesChecker` upgraded with the rule-count ceiling
    - `:three_amigos_task_started` shared given ✓
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "evaluate fails when story has too many rules", criterion: 158 do
    scenario "evaluate_task fails on rules < 15 and instructs the PM to slice" do
      given_ :persona_exists

      given_ "fifteen rules exist on the story, each with happy + failure scenarios", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        for n <- 1..15 do
          statement = "Rule number #{n}"

          _add_rule =
            ToolLibrary.run(
              "add_rule",
              %{story_number: context.story.number, statement: statement},
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )

          _happy =
            ToolLibrary.run(
              "add_scenario",
              %{
                story_number: context.story.number,
                rule_statement: statement,
                title: "Happy path for rule #{n}",
                kind: "happy_path",
                body: "Given context\nWhen action\nThen happy outcome"
              },
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )

          _failure =
            ToolLibrary.run(
              "add_scenario",
              %{
                story_number: context.story.number,
                rule_statement: statement,
                title: "Failure path for rule #{n}",
                kind: "failure_path",
                body: "Given context\nWhen action\nThen failure outcome"
              },
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )
        end

        {:ok, context}
      end

      given_ :three_amigos_task_started

      when_ "the agent calls evaluate_task on the Three Amigos task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the response surfaces the rules-ceiling failure and slice instruction",
            context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/rules?\s*<\s*15|too many rules|slice/i,
               "expected response to name the rules-ceiling failure and slice instruction, got #{inspect(context.evaluate_response)}"

        {:ok, context}
      end
    end
  end
end
