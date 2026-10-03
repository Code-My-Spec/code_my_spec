defmodule CodeMySpecSpex.Story1089.Criterion1846Spex do
  @moduledoc """
  Story 1089 — QA evidence is kept with its QA result
  Criterion 1846 — QA evidence binaries stay out of git.

  `CodeMySpec.Qa.Evidence` used to refuse a submission until the agent ran
  `git -C .code_my_spec add/commit/push` over its screenshots — the only
  code path in this product that ever asked a human or agent to commit
  these binaries. Evidence now goes to S3 instead, and that refusal (and
  the three git commands it handed over) is gone outright: nothing in
  `submit_qa_result`'s response, on any outcome, tells anyone to add a
  screenshot to git.

  Surface: `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "QA evidence binaries stay out of git", criterion: 1846 do
    scenario "a pass with a screenshot on disk names no git command" do
      given_ "a screenshot sits in the story's screenshot directory", context do
        dir = Path.join([".code_my_spec/qa", to_string(context.story.number), "screenshots"])
        :ok = Environments.write_file(context.environment, Path.join(dir, "one.png"), "fake-png")

        Req.Test.stub(CodeMySpec.Uploads, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

        {:ok, context}
      end

      when_ "the agent submits a passing result", context do
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

      then_ "nothing in the response asks for a git command", context do
        refute context.submit_response.isError,
               "expected success, got error: #{inspect(context.submit_response)}"

        text = response_text(context.submit_response)

        refute text =~ ~r/git\s+-C\s+\.code_my_spec/,
               "the response still tells the agent to commit evidence to git:\n#{text}"

        refute text =~ ~r/\bcommit\b.*\bpush\b/i,
               "the response still reads like a commit-and-push instruction:\n#{text}"

        {:ok, context}
      end
    end
  end
end
