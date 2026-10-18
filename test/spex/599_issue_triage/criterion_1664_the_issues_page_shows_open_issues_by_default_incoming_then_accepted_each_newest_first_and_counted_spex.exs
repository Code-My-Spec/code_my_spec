defmodule CodeMySpecSpex.Story599.Criterion1664Spex do
  @moduledoc """
  Story 599 — Issue Triage.
  Criterion 1664 — The issues page shows open issues by default: incoming, then
  accepted, each newest first and counted.

  What needs triage comes first, then what is being worked, and the newest of
  each on top.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Open issues by status, newest first", criterion: 1664 do
    scenario "two incoming and two accepted issues" do
      given_ "issues reported over time, two of them accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        issues =
          for title <- ~w(old-accepted old-incoming new-accepted new-incoming),
              do: Fixtures.issue_fixture(context.scope, %{title: title, severity: :high})

        for issue <- issues, String.ends_with?(issue.title, "accepted") do
          response =
            ToolLibrary.run(
              "accept_issue",
              %{issue_id: issue.id, category: "bug"},
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, response), inspect(response)
        end

        {:ok, context}
      end

      when_ "I open the issues page", context do
        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/issues")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "incoming come first, then accepted, newest first in each", context do
        order =
          ~r/(new|old)-(incoming|accepted)/
          |> Regex.scan(context.html)
          |> Enum.map(&hd/1)
          |> Enum.dedup()

        assert order == ~w(new-incoming old-incoming new-accepted old-accepted),
               "expected incoming then accepted, newest first; got #{inspect(order)}"

        {:ok, context}
      end

      then_ "each group shows how many it holds", context do
        for status <- ~w(incoming accepted) do
          assert context.html =~
                   ~r/data-status="#{status}".*?#{status}\s*<span[^>]*>\(2\)<\/span>/s,
                 "the #{status} group has no count of 2"
        end

        {:ok, context}
      end
    end
  end
end
