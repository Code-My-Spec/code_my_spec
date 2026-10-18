defmodule CodeMySpecSpex.Story1089.Criterion1849Spex do
  @moduledoc """
  Story 1089 — QA evidence is kept with its QA result
  Criterion 1849 — Evidence is viewable from the QA result.

  Two claims, both exercised here: the link the story's QA history
  (`QaHistoryComponent`) shows the agent's uploaded file under actually
  serves the bytes back (`QaEvidenceController`, same-origin — the same
  reasoning `IssueScreenshotController` already follows for issue
  screenshots, so the image loads under the app's own `img-src 'self'`
  CSP rather than a cross-origin presigned GET) — and the story page
  names that same file.

  Checked in two separate requests over the same `conn`, deliberately:
  `live/2` dispatches the story page through it, which leaves it sent, so
  the evidence fetch that follows uses its own fresh connection rather
  than continuing to drive an already-completed one.

  Surface: `CodeMySpecWeb.StoryLive.Show` and
  `CodeMySpecWeb.QaEvidenceController`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Evidence is viewable from the QA result", criterion: 1849 do
    scenario "the story page links the upload, and the link serves it back" do
      given_ "a screenshot is uploaded by a passing attempt", context do
        dir = Path.join([".code_my_spec/qa", to_string(context.story.number), "screenshots"])
        :ok = Environments.write_file(context.environment, Path.join(dir, "one.png"), "fake-png")

        Req.Test.stub(CodeMySpec.Uploads, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

        Req.Test.stub(CodeMySpec.Content.S3Client, fn conn ->
          Plug.Conn.send_resp(conn, 200, "fake-png")
        end)

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

      when_ "Sam follows the evidence URL for that upload", context do
        href = "/app/qa_attempts/#{context.attempt_id}/evidence/one.png"
        conn = get(context.conn, href)

        {:ok, Map.merge(context, %{href: href, evidence_conn: conn})}
      end

      then_ "it serves the uploaded bytes", context do
        assert context.evidence_conn.status == 200
        assert context.evidence_conn.resp_body == "fake-png"

        assert get_resp_header(context.evidence_conn, "content-type") |> List.first() =~
                 "image/png"

        {:ok, context}
      end

      then_ "and the story's own QA history names it at that same URL", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/stories/#{context.story.number}"
          )

        document = Floki.parse_document!(render(view))
        link = Floki.find(document, "[data-test='qa-evidence-link']")

        assert link != [], "no evidence link on the story page at all"
        assert Floki.attribute(link, "data-name") == ["one.png"]
        assert Floki.attribute(link, "href") == [context.href]

        {:ok, context}
      end
    end
  end
end
