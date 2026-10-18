defmodule CodeMySpecSpex.Story559.Criterion5898Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5898 — Resolved questions do not count against the
  readiness gate — only open ones do. The PM can resolve a
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

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "resolved questions do not block readiness", criterion: 165 do
    scenario "evaluate passes when more questions exist but enough are resolved" do
      given_ :persona_exists

      given_ "one rule with happy + failure scenarios exists", context do
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

      given_ "three questions are added and two are resolved", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        question_ids =
          for n <- 1..3 do
            response =
              ToolLibrary.run(
                "add_question",
                %{
                  story_number: context.story.number,
                  text: "Open question #{n}"
                },
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            extract_question_id(response)
          end

        for qid <- Enum.take(question_ids, 2) do
          _resolve_response =
            ToolLibrary.run("resolve_question", %{question_id: qid}, %{
              scope: frame.assigns.current_scope
            })
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

    extract_question_id(Regex.run(~r/id:\s*`?([0-9a-f-]{36})`?/, body), response)
  end

  defp extract_question_id([_, id], _response), do: id

  defp extract_question_id(_, response),
    do: raise("Could not extract question id from response: " <> inspect(response))
end
