defmodule CodeMySpecSpex.Story726.Criterion6444Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6444 — Submit succeeds when no brief file exists on disk.

  Demonstrates the brief-is-optional rule: the agent can submit a
  passing QA outcome without ever writing a brief.md. The submit
  succeeds and the response does not warn about a missing brief.

  Surface: `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "A planning brief is the agent's optional scratchpad" do
    scenario "Submit succeeds when no brief file exists on disk" do
      given_ "a started qa_complete task and no brief.md under .code_my_spec/qa/<story_id>/",
             context do
        brief_path = ".code_my_spec/qa/#{context.story.id}/brief.md"

        refute Environments.file_exists?(context.environment, brief_path),
               "precondition: expected no brief.md on disk"

        {:ok, context}
      end

      when_ "the agent calls submit_qa_result with status pass", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            frame
          )

        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "the call succeeds with no warning about a missing brief", context do
        refute context.submit_response.isError,
               "expected success, got error: #{inspect(context.submit_response)}"

        # And an attempt to show for it. Every assertion in this scenario is a
        # refute, so a reply carrying no error and no attempt satisfies all of
        # them — "submit succeeds" is the title's own claim and nothing was
        # checking it.
        assert extract_attempt_id!(context.submit_response),
               "expected a successful submit to record an attempt"

        text = response_text(context.submit_response)

        # The complaint, not the word.
        #
        # This refuted `~r/brief/i` outright, which was fair when nothing else
        # in a submit response mentioned one. `Qa.Evidence` now appends "make
        # sure `.code_my_spec` is committed and pushed where the brief was
        # written, or the claim outlives its evidence" — a sentence about
        # whether the evidence survives, not about the brief being absent. The
        # step asks for no warning about a *missing* brief, and there is none;
        # matching the bare word turned an unrelated feature into a failure.
        refute text =~ ~r/(missing|no|without a) brief/i,
               "expected no complaint about an absent brief; got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
