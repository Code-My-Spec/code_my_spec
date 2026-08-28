defmodule CodeMySpecSpex.Story559.Criterion5897Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion — While any question (red card) is open, the readiness
  gate fails and the failure detail names the unanswered questions
  and points the PM at `resolve_question`.

  This drove the ratio rule — `scenarios > questions`, Wynne's
  Example Mapping signal — and now drives the rule that replaced it:
  every red card answered, whatever the scenario count. The ratio
  reads whether a story is ready to *estimate* and says nothing about
  whether the conversation finished. A story with five scenarios and
  three open questions satisfied it, and nothing ever asked those
  three again; 50 released stories on this project were sitting in
  exactly that shape.

  The case here — more questions than scenarios — still fails, which
  is why this criterion survived the change. It is now one case of a
  stricter rule rather than the boundary itself.

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

  spex "evaluate fails while a red card is unanswered" do
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

        # The rule this criterion names is now a case of a stricter one: any
        # open red card blocks, not just more red than green. It still fails
        # here — with more questions than scenarios — so the criterion holds;
        # the message it produces is about the question rather than the ratio.
        assert body =~ ~r/open question/i,
               "expected the response to name the unanswered red card(s), got " <>
                 inspect(context.evaluate_response)

        {:ok, context}
      end
    end
  end

  defp assert_question_created(true, response, n),
    do: raise("AddQuestion #{n} failed: #{inspect(response)}")

  defp assert_question_created(_isError, _response, _n), do: :ok
end
