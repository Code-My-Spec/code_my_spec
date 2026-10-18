defmodule CodeMySpecSpex.Story599.Criterion1665Spex do
  @moduledoc """
  Story 599 — Issue Triage.
  Criterion 1665 — Resolved and dismissed issues are hidden by default and
  shown by choosing them in the status filter.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Closed issues are out of the way until asked for", criterion: 1665 do
    scenario "one open, one dismissed, one resolved" do
      given_ "an open issue, a dismissed one and a resolved one", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        _open = Fixtures.issue_fixture(context.scope, %{title: "still-open", severity: :high})

        dismissed =
          Fixtures.issue_fixture(context.scope, %{title: "was-dismissed", severity: :high})

        resolved =
          Fixtures.issue_fixture(context.scope, %{title: "was-resolved", severity: :high})

        r1 =
          ToolLibrary.run(
            "dismiss_issue",
            %{issue_id: dismissed.id, reason: "duplicate"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: resolved.id, category: "bug"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, accepted), inspect(accepted)

        r2 =
          ToolLibrary.run(
            "resolve_issue",
            %{issue_id: resolved.id, resolution: "fixed"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, r1), inspect(r1)
        assert match?({:ok, _}, r2), inspect(r2)

        {:ok, context}
      end

      when_ "I open the issues page, then choose each status in the filter", context do
        {:ok, live, default} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/issues")

        filter = fn status ->
          live |> form("form[phx-change='filter']", %{status: status}) |> render_change()
        end

        {:ok,
         Map.merge(context, %{
           default: default,
           all: filter.("all"),
           dismissed: filter.("dismissed"),
           resolved: filter.("resolved")
         })}
      end

      then_ "by default only the open issue shows", context do
        assert context.default =~ "still-open", "the open issue is missing by default"
        refute context.default =~ "was-dismissed", "a dismissed issue shows by default"
        refute context.default =~ "was-resolved", "a resolved issue shows by default"

        {:ok, context}
      end

      then_ "choosing them in the filter shows them", context do
        assert context.all =~ "was-dismissed" and context.all =~ "was-resolved",
               "All does not show the closed issues"

        assert context.dismissed =~ "was-dismissed" and not (context.dismissed =~ "was-resolved"),
               "Dismissed does not show just the dismissed issue"

        assert context.resolved =~ "was-resolved" and not (context.resolved =~ "was-dismissed"),
               "Resolved does not show just the resolved issue"

        {:ok, context}
      end
    end
  end
end
