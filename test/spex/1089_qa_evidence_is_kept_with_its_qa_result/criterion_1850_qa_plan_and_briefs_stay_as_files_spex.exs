defmodule CodeMySpecSpex.Story1089.Criterion1850Spex do
  @moduledoc """
  Story 1089 — QA evidence is kept with its QA result
  Criterion 1850 — QA plan and briefs stay as files.

  `EvidenceUpload.collect/4` only ever lists `<story>/screenshots/` — a
  brief or a plan lives one level up, at `<story>/brief.md`, so it is
  never a candidate to begin with. Proven here rather than assumed: a
  brief sits beside a screenshot in the same submission, and only the
  screenshot reaches S3.

  Surface: `CodeMySpec.Qa.EvidenceUpload`, driving
  `CodeMySpec.Qa.Tools.SubmitQaResult`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "QA plan and briefs stay as files", criterion: 1850 do
    scenario "a brief beside a screenshot — only the screenshot uploads" do
      given_ "a brief.md and a screenshot both exist for this story", context do
        story_dir = Path.join(".code_my_spec/qa", to_string(context.story.number))

        :ok =
          Environments.write_file(
            context.environment,
            Path.join(story_dir, "brief.md"),
            "# brief\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            Path.join([story_dir, "screenshots", "one.png"]),
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

        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "exactly the screenshot was uploaded, never the brief", context do
        text = response_text(context.submit_response)

        assert text =~ "evidence: 1 file(s) uploaded — one.png",
               "expected exactly one.png uploaded, got:\n#{text}"

        refute text =~ "brief.md", "the brief was treated as evidence"

        {:ok, context}
      end

      then_ "and the brief is still on disk, untouched", context do
        path = Path.join([".code_my_spec/qa", to_string(context.story.number), "brief.md"])

        assert {:ok, "# brief\n"} = Environments.read_file(context.environment, path)

        {:ok, context}
      end
    end
  end
end
