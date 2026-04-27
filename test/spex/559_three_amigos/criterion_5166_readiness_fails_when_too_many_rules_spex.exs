defmodule CodeMySpecSpex.Story559.Criterion5166Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5166 — When a story has 10 or more rules, the readiness
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

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "evaluate fails when story has too many rules" do
    scenario "evaluate_task fails on rules < 10 and instructs the PM to slice" do
      given_ :persona_exists

      given_ "ten rules exist on the story, each with happy + failure scenarios", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        for n <- 1..10 do
          statement = "Rule number #{n}"

          {:reply, _add_rule, _frame} =
            AddRule.execute(
              %{story_id: context.story.id, statement: statement},
              frame
            )

          {:reply, _happy, _frame} =
            AddScenario.execute(
              %{
                story_id: context.story.id,
                rule_statement: statement,
                title: "Happy path for rule #{n}",
                kind: "happy_path",
                body: "Given context\nWhen action\nThen happy outcome"
              },
              frame
            )

          {:reply, _failure, _frame} =
            AddScenario.execute(
              %{
                story_id: context.story.id,
                rule_statement: statement,
                title: "Failure path for rule #{n}",
                kind: "failure_path",
                body: "Given context\nWhen action\nThen failure outcome"
              },
              frame
            )
        end

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

      then_ "the response surfaces the rules-ceiling failure and slice instruction",
            context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/rules?\s*<\s*10|too many rules|slice/i,
               "expected response to name the rules-ceiling failure and slice instruction, got #{inspect(context.evaluate_response)}"

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
