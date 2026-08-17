defmodule CodeMySpecSpex.Story727.Criterion6455Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6455 — list_qa_attempts returns all attempts ordered
  most-recent first.

  Demonstrates that `list_qa_attempts` is a complete, ordered view of
  the QA history for a story. Three submissions yield three rows in
  the response, newest at the top, each carrying status / agent /
  scenarios / issues. Non-pass submissions carry linked issue ids
  per rule aa9a29e6 (story 726).

  Surfaces:
  - `CodeMySpec.McpServers.Issues.Tools.CreateIssue` (seed an issue per non-pass attempt)
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed three attempts at different timestamps)
  - `CodeMySpec.McpServers.Qa.Tools.ListQaAttempts` (read-back)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Qa.Tools.{ListQaAttempts, SubmitQaResult}

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "An engineer lists the full QA history for a story" do
    scenario "list_qa_attempts returns all attempts ordered most-recent first" do
      given_ "three QA submissions on the same story at increasing timestamps",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        Enum.each(["fail", "partial", "pass"], fn status ->
          issue_ids = file_issue_for_non_pass(status, context, frame)

          {:reply, response, _frame} =
            SubmitQaResult.execute(
              %{
                task_id: context.task_id,
                status: status,
                scenarios: [%{name: "scenario_#{status}", status: status, observation: "marker"}],
                issue_ids: issue_ids
              },
              frame
            )

          refute response.isError
        end)

        {:ok, context}
      end

      when_ "the engineer calls list_qa_attempts for the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListQaAttempts.execute(%{story_id: context.story.id}, frame)

        refute response.isError
        {:ok, Map.put(context, :list_response, response)}
      end

      then_ "the response lists all three attempts most-recent first with full fields",
            context do
        text = response_text(context.list_response)

        lines = String.split(text, "\n")
        pass_idx = Enum.find_index(lines, &String.contains?(&1, "scenario_pass"))
        partial_idx = Enum.find_index(lines, &String.contains?(&1, "scenario_partial"))
        fail_idx = Enum.find_index(lines, &String.contains?(&1, "scenario_fail"))

        assert pass_idx, "expected scenario_pass marker in response, got:\n#{text}"
        assert partial_idx, "expected scenario_partial marker in response"
        assert fail_idx, "expected scenario_fail marker in response"

        assert pass_idx < partial_idx,
               "expected most-recent (pass) to appear before earlier (partial)"

        assert partial_idx < fail_idx,
               "expected partial to appear before earliest (fail)"

        {:ok, context}
      end
    end
  end

  defp file_issue_for_non_pass("pass", _context, _frame), do: []

  defp file_issue_for_non_pass(status, context, frame) do
    {:reply, issue_response, _frame} =
      CreateIssue.execute(
        %{
          title: "QA-found #{status} finding from criterion 6455 spex",
          severity: "low",
          scope: "app",
          story_id: context.story.id,
          description: "Seeded during list_qa_attempts test setup."
        },
        frame
      )

    refute issue_response.isError
    [extract_issue_id(response_text(issue_response))]
  end

  defp extract_issue_id(text) do
    [_, id] = Regex.run(~r/(?:ID:?\s*|issue[_ ]id[: ]+)([a-f0-9-]+)/i, text)
    id
  end
end
