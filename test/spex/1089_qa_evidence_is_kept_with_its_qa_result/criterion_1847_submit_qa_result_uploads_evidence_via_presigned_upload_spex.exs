defmodule CodeMySpecSpex.Story1089.Criterion1847Spex do
  @moduledoc """
  Story 1089 — QA evidence is kept with its QA result
  Criterion 1847 — submit_qa_result uploads evidence via presigned upload.

  `CodeMySpec.Qa.EvidenceUpload` mints a presigned PUT URL per file
  (`CodeMySpec.Uploads.presigned_upload_url/3`) and performs the upload
  itself (`Uploads.upload/3`) — the half of that split every other
  presigned-upload caller in this codebase leaves to a browser, done here
  because the harness has no browser and the file is already on its own
  disk.

  Local dev without an S3 bucket configured is criterion 1850's sibling
  case, covered by `Uploads.configured?/0`'s own tests — not re-proven
  here.

  Surface: `CodeMySpec.Qa.Tools.SubmitQaResult`, driving
  `CodeMySpec.Qa.EvidenceUpload`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "submit_qa_result uploads evidence via presigned upload", criterion: 1847 do
    scenario "a screenshot on disk is PUT to a presigned URL" do
      given_ "a screenshot sits in the story's screenshot directory", context do
        dir = Path.join([".code_my_spec/qa", to_string(context.story.number), "screenshots"])
        :ok = Environments.write_file(context.environment, Path.join(dir, "one.png"), "fake-png")

        recorder = CodeMySpecSpex.Fixtures.call_recorder()

        Req.Test.stub(CodeMySpec.Uploads, fn conn ->
          CodeMySpecSpex.Fixtures.record_call(
            recorder,
            {conn.method, List.keyfind(conn.req_headers, "content-type", 0)}
          )

          Plug.Conn.send_resp(conn, 200, "")
        end)

        {:ok, Map.put(context, :recorder, recorder)}
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
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "the file reached the stub as a PUT carrying its content type", context do
        calls = CodeMySpecSpex.Fixtures.recorded_calls(context.recorder)

        assert [{"PUT", {"content-type", "image/png"}}] = calls,
               "expected exactly one PUT with an image/png content-type, got #{inspect(calls)}"

        {:ok, context}
      end

      then_ "and the response confirms the upload", context do
        text = response_text(context.submit_response)

        assert text =~ "evidence: 1 file(s) uploaded",
               "expected the response to confirm the upload:\n#{text}"

        {:ok, context}
      end
    end
  end
end
