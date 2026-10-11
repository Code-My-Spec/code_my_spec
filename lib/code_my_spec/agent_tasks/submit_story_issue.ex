defmodule CodeMySpec.AgentTasks.SubmitStoryIssue do
  @moduledoc "A story issue fix is submitted for the story's shared QA pass."

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.Issues

  def dispatch(_node),
    do: "Fix this story issue and submit the revision and evidence for shared story QA."

  def command(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      nil ->
        {:error, "Issue #{task.issue_id} no longer exists."}

      issue ->
        {:ok,
         """
         # Submit story issue: #{issue.title}

         Scope: **#{issue.scope}**.

         #{issue.description}

         Fix this issue as part of your assigned story. You may work on several
         story issues together. Commit and test the fixes, then call
         `submit_story_issue` with issue_id `#{issue.id}`, the exact `revision`,
         and `evidence` naming changed files, the fix, and exact verification
         commands and results. Verify the behavior in the issue's scope. Submit each affected
         issue. Submission does not resolve it: the story has one shared QA pass
         and promotion completes the reviewed fixes.

         Repair or add regression coverage for the behavior. Do not skip tests,
         mark them pending, or silence failures to make the graph pass.

         #{WriteBddSpecs.obsolete_criterion()}

         Call `evaluate_task` with task_id `#{task.id}` once submitted.
         """}
    end
  end

  def evaluate(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      %{story_submission_ref: ref} when is_binary(ref) -> {:ok, :valid}
      nil -> {:error, "Issue #{task.issue_id} no longer exists."}
      _ -> {:ok, :invalid, "Submit this fix with its revision and evidence before evaluation."}
    end
  end
end
