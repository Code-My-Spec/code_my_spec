defmodule CodeMySpecSpex.Story727.Criterion6474Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6474 — Engineer opens the QA index from the sidebar and
  sees the default view.

  Demonstrates the project-wide QA attempts index: a flat list of
  attempts across the project's stories, defaulted to the
  most-recent attempt per story with invalidated attempts hidden.
  Each visible row links back to that story's page.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed)
  - `CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt` (seed)
  - `CodeMySpecLocalWeb.QaLive` at `/projects/:project_name/qa`
    (the render surface)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{InvalidateQaAttempt, SubmitQaResult}
  alias CodeMySpecSpex.Fixtures
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "The project-wide QA index defaults to most-recent-per-story without invalidated" do
    scenario "Engineer opens the QA index from the sidebar and sees the default view" do
      given_ "QA attempts on three stories — story B has an older invalidated attempt and a newer pass",
             context do
        scope = context.scope
        frame = %Frame{assigns: %{current_scope: scope}}

        # Story A — single passed attempt (reuses the seeded story + task).
        {:reply, resp_a, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "story-a-only", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            frame
          )

        refute resp_a.isError

        # Story B — older pass (will be invalidated) then a newer pass.
        {story_b, task_id_b, _session_b} =
          Fixtures.qa_story_task_fixture(scope, title: "QA Index Spex Story B")

        {:reply, resp_b_old, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: task_id_b,
              status: "pass",
              scenarios: [%{name: "story-b-stale", status: "pass", observation: "stale"}],
              issue_ids: []
            },
            frame
          )

        refute resp_b_old.isError
        old_b_attempt_id = extract_attempt_id(response_text(resp_b_old))

        {:reply, inv_resp, _frame} =
          InvalidateQaAttempt.execute(
            %{attempt_id: old_b_attempt_id, reason: "spex seed: stale pass"},
            frame
          )

        refute inv_resp.isError

        {:reply, resp_b_new, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: task_id_b,
              status: "pass",
              scenarios: [%{name: "story-b-fresh", status: "pass", observation: "fresh"}],
              issue_ids: []
            },
            frame
          )

        refute resp_b_new.isError

        # Story C — single passed attempt.
        {story_c, task_id_c, _session_c} =
          Fixtures.qa_story_task_fixture(scope, title: "QA Index Spex Story C")

        {:reply, resp_c, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: task_id_c,
              status: "pass",
              scenarios: [%{name: "story-c-only", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            frame
          )

        refute resp_c.isError

        {:ok,
         context
         |> Map.put(:story_b, story_b)
         |> Map.put(:story_c, story_c)}
      end

      when_ "the engineer navigates to the project-wide QA index", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/qa")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the index renders the most-recent attempt per story", context do
        assert context.html =~ "story-a-only", "expected story A's only pass to render"
        assert context.html =~ "story-b-fresh", "expected story B's latest pass to render"
        assert context.html =~ "story-c-only", "expected story C's only pass to render"

        {:ok, context}
      end

      and_ "older and invalidated attempts are hidden by default", context do
        refute context.html =~ "story-b-stale",
               "expected story B's invalidated older pass to be hidden by default"

        refute context.html =~ "spex seed: stale pass",
               "expected the invalidation reason to be hidden by default"

        {:ok, context}
      end

      and_ "each row shows story title, status, agent, timestamp, and links to the story page",
           context do
        assert context.html =~ context.story.title,
               "expected story A's title in the index"

        assert context.html =~ context.story_b.title,
               "expected story B's title in the index"

        assert context.html =~ context.story_c.title,
               "expected story C's title in the index"

        assert context.html =~ ~r/pass/i, "expected status pass rendered"
        assert context.html =~ ~r/\d{4}-\d{2}-\d{2}/, "expected an ISO timestamp"

        story_b_path = "/app/projects/#{context.project.id}/stories/#{context.story_b.id}"

        assert context.html =~ story_b_path,
               "expected the row to link to the story's page"

        {:ok, context}
      end
    end
  end

  defp extract_attempt_id(text), do: extract_attempt_id_from(Regex.run(~r/attempt[_ ]id[: ]+([a-f0-9-]+)/i, text), text)

  defp extract_attempt_id_from([_, id], _text), do: id
  defp extract_attempt_id_from(_, text), do: raise("no attempt_id in submit response: #{text}")
end
