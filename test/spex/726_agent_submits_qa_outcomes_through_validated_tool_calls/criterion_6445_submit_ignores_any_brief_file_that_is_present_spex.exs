defmodule CodeMySpecSpex.Story726.Criterion6445Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6445 — Submit ignores any brief file that is present.

  Demonstrates the brief-is-optional rule from the other side: a
  brief.md with arbitrary content is on disk, but submit succeeds
  without parsing or referencing it.

  Surfaces:
  - `CodeMySpec.Environments` (seed the brief)
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "The harness never reads the agent's brief scratchpad" do
    scenario "Submit ignores any brief file that is present" do
      given_ "a started qa_complete task and a brief.md with arbitrary content on disk",
             context do
        brief_path = ".code_my_spec/qa/#{context.story.id}/brief.md"

        :ok =
          Environments.write_file(
            context.environment,
            brief_path,
            "# garbage\n\nthis brief is malformed nonsense the harness must ignore\n"
          )

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

      then_ "the call succeeds and the brief content is not referenced in the response",
            context do
        refute context.submit_response.isError

        # And an attempt to show for it. Every assertion in this scenario is a
        # refute, so a reply carrying no error and no attempt satisfies all of
        # them — "submit succeeds" is the title's own claim and nothing was
        # checking it.
        assert extract_attempt_id!(context.submit_response),
               "expected a successful submit to record an attempt"

        text = response_text(context.submit_response)

        refute text =~ "garbage",
               "expected brief content to be ignored, got:\n#{text}"

        refute text =~ "malformed",
               "expected no parsing of brief, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
