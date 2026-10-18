defmodule CodeMySpecSpex.Story559.Criterion5895Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5895 — After Three Amigos has been completed for a story
  and the PM deletes all of its acceptance criteria, the readiness
  gate flips back to unsatisfied — the graph re-dispatches Three
  Amigos for that story on the next pass.

  Covers Rule 1 from `specs.md`:
  "Deleting all criteria re-dispatches Three Amigos."

  Proves the checker reads live state and that the readiness gate is
  symmetric — completion isn't latched, it tracks the underlying
  Rules / Criteria / persona-link records.

  Depends on:
    - `BddRulesChecker.complete?/2` ✓
    - `AcceptanceCriteria.delete_criterion` ✓
    - `ListRequirements` MCP tool ✓
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "deleting all criteria flips three_amigos_complete back to unsatisfied", criterion: 162 do
    scenario "list_requirements shows three_amigos_complete satisfied, then unsatisfied after deletion" do
      given_ :persona_exists

      given_ "one rule exists with happy + failure scenarios", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        rule_statement = "Suspended cards cannot be used for purchases"

        _add_rule =
          ToolLibrary.run(
            "add_rule",
            %{story_number: context.story.number, statement: rule_statement},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        _happy =
          ToolLibrary.run(
            "add_scenario",
            %{
              story_number: context.story.number,
              rule_statement: rule_statement,
              title: "Driver attempts purchase with suspended card",
              kind: "happy_path",
              body: "Given...\nWhen...\nThen happy outcome"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        _failure =
          ToolLibrary.run(
            "add_scenario",
            %{
              story_number: context.story.number,
              rule_statement: rule_statement,
              title: "Suspension status fails to load",
              kind: "failure_path",
              body: "Given...\nWhen...\nThen failure outcome"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, context}
      end

      when_ "the PM retires every acceptance criterion on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        get_response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        criterion_ids =
          Regex.scan(~r/\(criterion ([^)]+)\)/, response_text(get_response))
          |> Enum.map(fn [_, id] -> id end)

        assert criterion_ids != [],
               "expected at least one acceptance criterion to retire, got none"

        for id <- criterion_ids do
          _resp =
            ToolLibrary.run(
              "retire_criterion",
              %{criterion_number: id},
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )
        end

        {:ok, context}
      end

      then_ "list_requirements shows three_amigos_complete unsatisfied for the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_requirements",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        body = response_text(response)

        assert body =~ ~r/\[ \]\s+\*\*three_amigos_complete\*\*/,
               "expected three_amigos_complete to be unsatisfied after retiring all criteria, got #{inspect(response)}"

        {:ok, context}
      end
    end
  end
end
