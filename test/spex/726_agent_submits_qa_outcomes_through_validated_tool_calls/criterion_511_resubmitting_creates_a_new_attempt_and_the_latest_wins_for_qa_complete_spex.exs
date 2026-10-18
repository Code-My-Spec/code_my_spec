defmodule CodeMySpecSpex.Story726.Criterion6446Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6446 — Resubmitting creates a new attempt and the latest
  wins for qa_complete.

  Demonstrates the multi-submission rule: a partial submission
  followed by a pass submission results in two attempt rows in
  history, with qa_complete satisfied by the latest (pass). The
  partial submission carries an issue id per rule aa9a29e6.

  Surfaces:
  - `CodeMySpec.Issues.Tools.CreateIssue`
  - `CodeMySpec.Qa.Tools.SubmitQaResult` (x2)
  - `CodeMySpec.Qa.Tools.ListQaAttempts`
  - `CodeMySpec.Requirements.Tools.ListRequirements`
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Multiple submissions are allowed and the latest is canonical", criterion: 511 do
    scenario "Resubmitting creates a new attempt and the latest wins for qa_complete" do
      given_ "a started qa_complete task and an issue filed for the first-pass finding",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        issue_response =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "QA-found incomplete coverage from criterion 6446 spex",
              severity: "low",
              scope: "app",
              story_number: context.story.number,
              description: "First-pass partial submission discovered this gap."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, issue_response)
        issue_id = extract_issue_id(response_text(issue_response))

        {:ok, Map.put(context, :issue_id, issue_id)}
      end

      when_ "the agent submits partial then later submits pass on the same task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        partial_response =
          ToolLibrary.run(
            "submit_qa_result",
            %{
              task_id: context.task_id,
              status: "partial",
              scenarios: [%{name: "first_pass", status: "partial", observation: "incomplete"}],
              issue_ids: [context.issue_id]
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, partial_response)

        pass_response =
          ToolLibrary.run(
            "submit_qa_result",
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "second_pass", status: "pass", observation: "complete"}],
              issue_ids: []
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, pass_response)
        {:ok, context}
      end

      then_ "both attempts are visible in history and qa_complete is satisfied", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        list_response =
          ToolLibrary.run(
            "list_qa_attempts",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, list_response)
        text = response_text(list_response)

        assert text =~ "first_pass"
        assert text =~ "second_pass"

        # Satisfaction is observed via list_requirements — the agent-facing
        # MCP surface for requirement satisfaction.
        qa_text = satisfied_qa_complete_text(context.scope)

        assert qa_text =~ context.story.title,
               "expected qa_complete satisfied for story #{context.story.title} after the latest (pass) submit, got:\n#{qa_text}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(text) do
    [_, id] = Regex.run(~r/(?:ID:?\s*|issue[_ ]id[: ]+)([a-f0-9-]+)/i, text)
    id
  end
end
