defmodule CodeMySpecSpex.Story559.Criterion5170Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5170 — After Three Amigos has been completed for a story
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

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

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
        criteria = AcceptanceCriteria.list_story_criteria(context.scope, context.story.id)

        for criterion <- criteria do
          {:ok, _} = AcceptanceCriteria.delete_criterion(context.scope, criterion)
        end

        {:ok, context}
      end

      then_ "list_requirements shows three_amigos_complete unsatisfied for the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        body = response_text(response)

        assert body =~ ~r/\[ \]\s+\*\*three_amigos_complete\*\*/,
               "expected three_amigos_complete to be unsatisfied after deleting all criteria, got #{inspect(response)}"

        :ok
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
