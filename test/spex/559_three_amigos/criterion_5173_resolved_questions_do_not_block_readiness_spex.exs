defmodule CodeMySpecSpex.Story559.Criterion5173Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5173 — Resolved questions do not count against the
  `scenarios > questions` readiness clause. The PM can resolve a
  question via `resolve_question`, and the readiness gate passes
  even though the question record still exists in the audit trail.

  Covers the lifecycle of a question (`:open` → `:resolved`) and
  the asymmetry: only OPEN questions block readiness; resolved
  ones are historical.

  Depends on:
    - `BddRulesChecker` scenarios-vs-questions clause
    - `ResolveQuestion` MCP tool (new)
    - `Question.status` enum (new)
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddQuestion
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.BddRules.Tools.ResolveQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "resolved questions do not block readiness" do
    scenario "evaluate passes when more questions exist but enough are resolved" do
      given_ :persona_exists

      given_ "one rule with happy + failure scenarios exists", context do
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

      given_ "three questions are added and two are resolved", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        question_ids =
          for n <- 1..3 do
            {:reply, response, _frame} =
              AddQuestion.execute(
                %{
                  story_id: context.story.id,
                  text: "Open question #{n}"
                },
                frame
              )

            extract_question_id(response)
          end

        for qid <- Enum.take(question_ids, 2) do
          {:reply, _resolve_response, _frame} =
            ResolveQuestion.execute(%{question_id: qid}, frame)
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

      then_ "the response indicates the Three Amigos task passed", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/passed|complete/i,
               "expected response to indicate the task passed (resolved questions don't block), got #{inspect(context.evaluate_response)}"

        {:ok, context}
      end
    end
  end

  # Tools return text responses with embedded ids — extract the question id.
  defp extract_question_id(response) do
    body = response_text(response)

    case Regex.run(~r/id:\s*`?([0-9a-f-]{36})`?/, body) do
      [_, id] -> id
      _ -> raise "Could not extract question id from response: #{inspect(response)}"
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
