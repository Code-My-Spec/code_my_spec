defmodule CodeMySpecSpex.Story727.Criterion6460Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6460 — Engineer invalidates a pass from the story page
  UI.

  Demonstrates the in-browser invalidation flow: an engineer
  reading the QA history on a story page can invalidate a passed
  attempt directly via a confirm dialog. The submission requires
  a non-empty reason; the invalidation appears in the rendered
  chain after submission.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed)
  - `CodeMySpecLocalWeb.StoryLive` at
    `/projects/:project_name/stories/:id` (the action surface)
  - The `<.confirm_dialog>` component for the reason prompt
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Engineer invalidates a pass directly from the story page" do
    scenario "Engineer invalidates a pass from the story page UI" do
      given_ "a story with a passed QA attempt rendered on the local story page",
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
        attempt_id = extract_attempt_id(response_text(submit_response))

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories/#{context.story.id}")

        {:ok, context |> Map.put(:view, view) |> Map.put(:attempt_id, attempt_id)}
      end

      when_ "the engineer clicks invalidate and submits a non-empty reason", context do
        context.view
        |> element("[data-role='invalidate-qa-attempt'][data-attempt-id='#{context.attempt_id}']")
        |> render_click()

        context.view
        |> form("[data-role='invalidate-reason-form']", %{
          reason: "Shallow QA — needs redo with curl probes"
        })
        |> render_submit()

        {:ok, context}
      end

      then_ "the rendered chain shows the invalidation with the engineer's reason",
            context do
        html = render(context.view)

        assert html =~ "Shallow QA — needs redo with curl probes",
               "expected the reason to appear in the rendered chain"

        assert html =~ ~r/invalidated/i,
               "expected the attempt to be marked invalidated in the UI"

        {:ok, context}
      end
    end
  end

  defp extract_attempt_id(text),
    do: extract_attempt_id_from(Regex.run(~r/attempt[_ ]id[: ]+([a-f0-9-]+)/i, text), text)

  defp extract_attempt_id_from([_, id], _text), do: id
  defp extract_attempt_id_from(_, text), do: raise("no attempt_id in submit response: #{text}")
end
