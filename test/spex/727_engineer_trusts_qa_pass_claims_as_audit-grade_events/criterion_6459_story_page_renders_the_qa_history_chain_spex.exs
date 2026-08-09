defmodule CodeMySpecSpex.Story727.Criterion6459Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6459 — Story page renders the QA history chain.

  Demonstrates the engineer-in-a-browser surface: the local app's
  story page renders the QA history for that story, showing each
  attempt's status, agent, timestamp, scenarios, and any
  invalidation event with its reason.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed history)
  - `CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt` (seed
    invalidation event)
  - `CodeMySpecLocalWeb.StoryLive` at
    `/projects/:project_name/stories/:id` (the render surface)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{InvalidateQaAttempt, SubmitQaResult}
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "The story page renders the full QA history chain" do
    scenario "Story page renders the QA history chain" do
      given_ "three QA attempts on the story, one invalidated", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        attempt_ids =
          for marker <- ["alpha", "beta", "gamma"] do
            {:reply, response, _frame} =
              SubmitQaResult.execute(
                %{
                  task_id: context.task_id,
                  status: "pass",
                  scenarios: [%{name: marker, status: "pass", observation: marker}],
                  issue_ids: []
                },
                frame
              )

            refute response.isError
            extract_attempt_id(response_text(response))
          end

        [_, middle_id, _] = attempt_ids

        {:reply, _invalidate, _frame} =
          InvalidateQaAttempt.execute(
            %{attempt_id: middle_id, reason: "Test probe was incomplete"},
            frame
          )

        {:ok, context}
      end

      when_ "the engineer navigates to the local story page", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories/#{context.story.id}")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the QA history section renders all three attempts in order", context do
        assert context.html =~ "alpha"
        assert context.html =~ "beta"
        assert context.html =~ "gamma"

        {:ok, context}
      end

      and_ "the invalidated attempt shows its invalidation reason", context do
        assert context.html =~ "Test probe was incomplete",
               "expected invalidation reason in rendered html"

        assert context.html =~ ~r/invalidated/i,
               "expected the invalidated attempt to be visually marked"

        {:ok, context}
      end

      and_ "each attempt shows status, scenarios, and timestamp markers", context do
        assert context.html =~ ~r/pass/i, "expected status pass rendered"
        assert context.html =~ ~r/\d{4}-\d{2}-\d{2}/, "expected an ISO timestamp"

        {:ok, context}
      end
    end
  end

  defp extract_attempt_id(text), do: extract_attempt_id_from(Regex.run(~r/attempt[_ ]id[: ]+([a-f0-9-]+)/i, text), text)

  defp extract_attempt_id_from([_, id], _text), do: id
  defp extract_attempt_id_from(_, text), do: raise("no attempt_id in submit response: #{text}")
end
