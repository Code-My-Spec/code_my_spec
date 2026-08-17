defmodule CodeMySpecSpex.Story726.Criterion6443Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6443 — Finding flows through create_issue then is
  referenced by id in submit.

  Demonstrates the findings-as-issues rule: a defect discovered
  during probing is filed via `create_issue` (issuing an id) and
  the id is included in the submit's `issue_ids`. The attempt
  record links the issue; `list_issues` shows the issue on the
  story.

  Surfaces:
  - `CodeMySpec.McpServers.Issues.Tools.CreateIssue`
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  - `CodeMySpec.McpServers.Issues.Tools.ListIssues`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.{CreateIssue, ListIssues}
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Findings enter the system only via create_issue and submit references them by id" do
    scenario "Finding flows through create_issue then is referenced by id in submit" do
      given_ "a started qa_complete task and a defect surfaced by the agent's probing",
             context do
        {:ok, context}
      end

      when_ "the agent files the defect via create_issue and submits with that issue_id",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, issue_response, _frame} =
          CreateIssue.execute(
            %{
              title: "QA-found defect from criterion 6443 spex",
              severity: "low",
              scope: "app",
              story_id: context.story.id,
              description: "Discovered while probing the agent surface."
            },
            frame
          )

        refute issue_response.isError
        issue_id = extract_issue_id(response_text(issue_response))

        {:reply, submit_response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "probe", status: "pass", observation: "found one"}],
              issue_ids: [issue_id]
            },
            frame
          )

        refute submit_response.isError

        {:ok,
         context |> Map.put(:issue_id, issue_id) |> Map.put(:submit_response, submit_response)}
      end

      then_ "the issue is queryable on the story via list_issues", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListIssues.execute(%{story_id: context.story.id}, frame)

        refute list_response.isError
        text = response_text(list_response)

        assert text =~ context.issue_id,
               "expected issue #{context.issue_id} listed on story, got:\n#{text}"

        {:ok, context}
      end

      and_ "the submit response acknowledges the linked issue_id", context do
        text = response_text(context.submit_response)

        assert text =~ context.issue_id or text =~ ~r/issue[_ ]id/i,
               "expected linked issue_id surfaced in submit response, got:\n#{text}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(text),
    do:
      extract_issue_id_from(Regex.run(~r/(?:ID:?\s*|issue[_ ]id[: ]+)([a-f0-9-]+)/i, text), text)

  defp extract_issue_id_from([_, id], _text), do: id
  defp extract_issue_id_from(_, text), do: raise("no issue id in create_issue response: #{text}")
end
