defmodule CodeMySpec.AgentPerformance.ReportTest do
  @moduledoc """
  The performance page as Markdown, for an agent to plan improvements from:
  the same sections and numbers, through the page's download and the
  `agent_performance_report` tool (John, 2026-10-15).
  """
  use CodeMySpecSpex.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.AgentPerformance.Report
  alias CodeMySpec.McpServers.AgentPerformance.Tools.AgentPerformanceReport
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentPerformanceHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    coder = Fixtures.running_agent(context.scope, role: "coding")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for status <- ["expired", "expired", "approved"] do
      Repo.insert!(%PermissionRequest{
        user_id: context.user.id,
        agent_id: coder.id,
        tool_name: "tap_out",
        tool_input: %{"reason" => "blocked"},
        status: status,
        inserted_at: now,
        updated_at: now
      })
    end

    :ok
  end

  test "it carries the page's sections, with a bad rate leading and its change first", context do
    md = Report.markdown(context.scope)

    for section <- [
          "## What stands out",
          "## What I'd change first",
          "## Activity by role",
          "## QA",
          "## Time per story",
          "## Blocked time",
          "## Offers by kind this week",
          "## Messages to agents by kind",
          "## Limits of this report"
        ] do
      assert md =~ section, "the report has no #{section} section"
    end

    assert md =~ "| Tap-outs expired undecided | 67% |"
    assert md =~ "1. **Tap-outs expired undecided: 67%** (bad). Never let a tap-out expire unseen"
    assert md =~ "| coding | 1 | 0 | 2 | 0 |", "the tap-outs table does not count the coder's"
  end

  test "an agent gets the same report from the tool", context do
    frame = %Frame{assigns: %{current_scope: context.scope}}
    {:reply, reply, _frame} = AgentPerformanceReport.execute(%{}, frame)

    [%{"text" => text}] = reply.content
    assert text =~ "# Agent performance"
    assert text =~ "Tap-outs expired undecided"
  end

  test "a story number the project does not have is refused, not ignored", context do
    frame = %Frame{assigns: %{current_scope: context.scope}}
    {:reply, reply, _frame} = AgentPerformanceReport.execute(%{"story_number" => 999_999}, frame)

    assert reply.isError
  end

  test "the page's download hands the browser the same Markdown", context do
    {:ok, index, _html} = live(context.conn, index_path(context))
    _ = render_async(index)

    index |> element("[data-test='export-report']") |> render_click()
    _ = render_async(index)

    assert_push_event(index, "download", %{filename: filename, content: content})
    assert filename =~ ~r/^agent-performance-\d{4}-\d{2}-\d{2}\.md$/
    assert content =~ "## What stands out"
  end
end
