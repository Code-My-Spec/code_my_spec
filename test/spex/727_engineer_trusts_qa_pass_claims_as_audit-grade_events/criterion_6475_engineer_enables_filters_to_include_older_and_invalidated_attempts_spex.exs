defmodule CodeMySpecSpex.Story727.Criterion6475Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6475 — Engineer enables filters to include older and
  invalidated attempts.

  Demonstrates the filter toggles on the project-wide QA index:
  the engineer can opt into showing older attempts and invalidated
  attempts so the index renders the full history rather than only
  the latest pass per story. Toggling either filter back off hides
  the corresponding rows without reloading the page.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed)
  - `CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt` (seed)
  - `CodeMySpecLocalWeb.QaLive` (render surface + filter toggles)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{InvalidateQaAttempt, SubmitQaResult}

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Filter toggles reveal older and invalidated attempts" do
    scenario "Engineer enables filters to include older and invalidated attempts" do
      given_ "the QA index in its default state with one older invalidated attempt and one newer pass",
             context do
        scope = context.scope
        frame = %Frame{assigns: %{current_scope: scope}}

        # Older pass (about to be invalidated).
        {:reply, older_resp, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "older-attempt", status: "pass", observation: "stale"}],
              issue_ids: []
            },
            frame
          )

        refute older_resp.isError
        older_id = extract_attempt_id(response_text(older_resp))

        {:reply, inv_resp, _frame} =
          InvalidateQaAttempt.execute(
            %{attempt_id: older_id, reason: "spex seed: superseded"},
            frame
          )

        refute inv_resp.isError

        # Newer pass on the same story.
        {:reply, newer_resp, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "newer-attempt", status: "pass", observation: "fresh"}],
              issue_ids: []
            },
            frame
          )

        refute newer_resp.isError

        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/qa")

        # Sanity-check the default view: only the newer attempt is visible.
        assert html =~ "newer-attempt", "default view should anchor on the newer pass"

        refute html =~ "older-attempt",
               "older attempt should be hidden by default"

        refute html =~ "spex seed: superseded",
               "invalidation reason should be hidden by default"

        {:ok, context |> Map.put(:view, view)}
      end

      when_ "the engineer toggles include-older and include-invalidated filters on", context do
        context.view
        |> element("[data-role='qa-index-filter-older']")
        |> render_click()

        context.view
        |> element("[data-role='qa-index-filter-invalidated']")
        |> render_click()

        {:ok, context}
      end

      then_ "the older invalidated attempt appears in the list with its badge and reason",
            context do
        html = render(context.view)

        assert html =~ "newer-attempt", "newer attempt remains visible"
        assert html =~ "older-attempt", "older attempt appears once filters include it"

        assert html =~ "spex seed: superseded",
               "the invalidation reason renders alongside the invalidated row"

        assert html =~ ~r/invalidated/i,
               "the invalidated row carries its badge"

        {:ok, context}
      end

      and_ "toggling either filter back off hides the rows again without a page reload",
           context do
        context.view
        |> element("[data-role='qa-index-filter-older']")
        |> render_click()

        context.view
        |> element("[data-role='qa-index-filter-invalidated']")
        |> render_click()

        html = render(context.view)

        assert html =~ "newer-attempt", "newer attempt remains visible after toggling off"

        refute html =~ "older-attempt",
               "older attempt hidden again once the filter is toggled off"

        refute html =~ "spex seed: superseded",
               "invalidation reason hidden again once the filter is toggled off"

        {:ok, context}
      end
    end
  end

  defp extract_attempt_id(text),
    do: extract_attempt_id_from(Regex.run(~r/attempt[_ ]id[: ]+([a-f0-9-]+)/i, text), text)

  defp extract_attempt_id_from([_, id], _text), do: id
  defp extract_attempt_id_from(_, text), do: raise("no attempt_id in submit response: #{text}")
end
