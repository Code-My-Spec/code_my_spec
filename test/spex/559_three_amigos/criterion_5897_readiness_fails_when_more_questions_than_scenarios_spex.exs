defmodule CodeMySpecSpex.Story559.Criterion5897Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5897 — When a story has more open questions (red cards)
  than scenarios (green cards), the readiness gate fails on the
  `scenarios > questions` clause and the failure detail tells the PM
  the story isn't ready.

  Enforces Wynne's Example Mapping signal: if there are more red
  cards than green cards, the story is not yet ready for development
  — the PM needs to find answers before the spec can be locked in.

  Depends on:
    - `BddRulesChecker` upgraded with the scenarios-vs-questions clause
    - `Questions` context (new)
    - `AddQuestion` MCP tool (new)
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddQuestion
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "evaluate fails when open questions outnumber scenarios" do
    scenario "evaluate_task names the scenarios-vs-questions readiness failure" do
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

      given_ "three open questions exist on the story (more than the two scenarios)",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        for n <- 1..3 do
          {:reply, response, _frame} =
            AddQuestion.execute(
              %{
                story_id: context.story.id,
                text: "Open question number #{n} that nobody can answer right now"
              },
              frame
            )

          # Loudly fail if question creation didn't succeed —
          # silent failures here would let the readiness assertion lie.
          assert_question_created(response.isError, response, n)
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

      then_ "the response surfaces the scenarios-vs-questions readiness failure",
            context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/scenarios?\s*>\s*questions?|too many open questions|story.*not.*ready/i,
               "expected response to name the scenarios>questions failure, got #{inspect(context.evaluate_response)}"

        {:ok, context}
      end
    end
  end

  defp assert_question_created(true, response, n),
    do: raise("AddQuestion #{n} failed: #{inspect(response)}")

  defp assert_question_created(_isError, _response, _n), do: :ok
end
