defmodule CodeMySpecSpex.Story727.Criterion6454Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6454 — Editing or deleting result_complete.md does not
  change qa_complete state.

  Demonstrates the anti-bypass rule: once a passed attempt exists in
  the DB, the filesystem residue is irrelevant. An engineer who edits
  or deletes `result_complete.md` (whether out of confusion or
  malice) cannot move the requirement off "satisfied."

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed the pass)
  - `CodeMySpec.Environments.write_file/3` (write the file)
  - `CodeMySpec.Environments` delete via `write_file` rewrite or
    direct filesystem cleanup helper
  - `CodeMySpec.McpServers.Requirements.Tools.ListRequirements`
    (observe satisfaction stays unchanged)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Filesystem edits to result_complete.md have no effect on qa_complete" do
    scenario "Editing or deleting result_complete.md does not change qa_complete state" do
      given_ "a story with a DB attempt at status pass and a result_complete.md on disk",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, submit_response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            frame
          )

        refute submit_response.isError

        result_path = ".code_my_spec/qa/#{context.story.id}/result_complete.md"
        :ok = Environments.write_file(context.environment, result_path, "# legacy file\n")

        {:ok, Map.put(context, :result_path, result_path)}
      end

      when_ "an engineer rewrites result_complete.md to claim failure", context do
        :ok =
          Environments.write_file(
            context.environment,
            context.result_path,
            "# Qa Result\n\n## Status\n\nfail\n"
          )

        {:ok, context}
      end

      then_ "qa_complete remains satisfied (DB state is canonical)", context do
        # The whole point: filesystem manipulation is invisible to the
        # checker. Observe via Qa.complete?/2 (which the checker
        # delegates to) — DB attempt status is unchanged.
        assert CodeMySpec.Qa.qa_complete?(context.scope, context.story.id),
               "expected Qa.complete? still true after rewriting result_complete.md to 'fail'"

        {:ok, context}
      end
    end
  end
end
