defmodule CodeMySpecSpex.Story559.Criterion5165Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5165 — When a rule exists with only a happy-path scenario
  and no failure-path scenario, the readiness gate fails on the
  per-rule coverage check, naming the rule as missing failure-path
  coverage.

  Exercises the per-rule coverage clause: "every rule has at least one
  happy-path and one failure-path scenario." This is stricter than the
  initial relaxed checker (which only required ≥1 criterion total) and
  is the BDD discipline rule from `rules.md`.

  Depends on:
    - `BddRulesChecker` upgraded to per-rule coverage check
    - `Criterion.kind` ✓
    - `:three_amigos_task_started` shared given ✓
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "evaluate fails when a rule has only a happy-path scenario" do
    scenario "evaluate_task names the rule as missing failure-path coverage" do
      given_ :persona_exists

      given_ "one rule exists with only a happy-path scenario", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        rule_statement = "Suspended cards cannot be used for purchases"

        {:reply, _add_rule_response, _frame} =
          AddRule.execute(
            %{story_id: context.story.id, statement: rule_statement},
            frame
          )

        {:reply, _happy_response, _frame} =
          AddScenario.execute(
            %{
              story_id: context.story.id,
              rule_statement: rule_statement,
              title: "Driver attempts purchase with suspended card",
              kind: "happy_path",
              body: """
              Given the driver's card is suspended
              When the driver attempts a purchase at point of sale
              Then the purchase is declined
              """
            },
            frame
          )

        {:ok, context}
      end

      given_ :three_amigos_task_started

      when_ "the agent calls evaluate_task on the Three Amigos task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the response surfaces the missing failure-path coverage", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/failure[-_ ]path|failure scenario/i,
               "expected response to name the missing failure-path coverage, got #{inspect(context.evaluate_response)}"

        {:ok, context}
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
