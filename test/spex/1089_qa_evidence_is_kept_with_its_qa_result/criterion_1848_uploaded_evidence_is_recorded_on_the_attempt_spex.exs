defmodule CodeMySpecSpex.Story1089.Criterion1848Spex do
  @moduledoc """
  Story 1089 — QA evidence is kept with its QA result
  Criterion 1848 — Uploaded evidence is recorded on the attempt.

  `QaAttempts.attach_evidence/2` is the only write this adds to the
  attempt after insert, and it lands on the row itself
  (`embeds_many :evidence`) rather than only in the one-time tool
  response — the difference between "was told once" and "can be asked
  later," which is what criterion 1849's own viewing depends on.

  Surface: `CodeMySpec.Qa.QaAttempts`, driving `CodeMySpec.Qa.QaAttempt`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Qa.QaAttempts

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Uploaded evidence is recorded on the attempt", criterion: 1848 do
    scenario "the attempt's own row names the file that was uploaded" do
      given_ "a screenshot sits in the story's screenshot directory", context do
        dir =
          Path.join([
            ".code_my_spec/qa",
            to_string(context.story.number),
            "screenshots",
            context.task_id
          ])

        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            Path.join(dir, "one.png"),
            "fake-png"
          )

        Req.Test.stub(CodeMySpec.Uploads, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

        {:ok, context}
      end

      when_ "the agent submits a passing result", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "submit_qa_result",
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :attempt_id, extract_attempt_id!(response))}
      end

      then_ "re-reading the attempt from storage shows the evidence", context do
        [stored] = QaAttempts.list(context.scope, context.story.id)

        assert to_string(stored.id) == context.attempt_id

        assert [%{name: "one.png", content_type: "image/png", bytes: bytes}] = stored.evidence
        assert bytes == byte_size("fake-png")

        {:ok, context}
      end
    end
  end
end
