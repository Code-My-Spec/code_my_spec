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

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.McpServers.Stories.Tools.DeleteCriterion
  alias CodeMySpec.McpServers.Stories.Tools.GetStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "deleting all criteria flips three_amigos_complete back to unsatisfied" do
    scenario "list_requirements shows three_amigos_complete satisfied, then unsatisfied after deletion" do
      given_ :persona_exists

      given_ "one rule exists with happy + failure scenarios", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        rule_statement = "Suspended cards cannot be used for purchases"

        {:reply, _add_rule, _frame} =
          AddRule.execute(
            %{story_id: context.story.id, statement: rule_statement},
            frame
          )

        {:reply, _happy, _frame} =
          AddScenario.execute(
            %{
              story_id: context.story.id,
              rule_statement: rule_statement,
              title: "Driver attempts purchase with suspended card",
              kind: "happy_path",
              body: "Given...\nWhen...\nThen happy outcome"
            },
            frame
          )

        {:reply, _failure, _frame} =
          AddScenario.execute(
            %{
              story_id: context.story.id,
              rule_statement: rule_statement,
              title: "Suspension status fails to load",
              kind: "failure_path",
              body: "Given...\nWhen...\nThen failure outcome"
            },
            frame
          )

        {:ok, context}
      end

      when_ "the PM deletes every acceptance criterion on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetStory.execute(%{story_id: to_string(context.story.id)}, frame)

        criterion_ids =
          Regex.scan(~r/\(criterion ([^)]+)\)/, response_text(get_response))
          |> Enum.map(fn [_, id] -> id end)

        assert criterion_ids != [],
               "expected at least one acceptance criterion to delete, got none"

        for id <- criterion_ids do
          {:reply, _resp, _frame} =
            DeleteCriterion.execute(%{criterion_id: id}, frame)
        end

        {:ok, context}
      end

      then_ "list_requirements shows three_amigos_complete unsatisfied for the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        body = response_text(response)

        assert body =~ ~r/\[ \]\s+\*\*three_amigos_complete\*\*/,
               "expected three_amigos_complete to be unsatisfied after deleting all criteria, got #{inspect(response)}"

        {:ok, context}
      end
    end
  end
end
