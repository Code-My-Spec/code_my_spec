defmodule CodeMySpecWeb.RequirementsLive.TheGraphPageNamesTheWriterThatKeepsItCurrentTest do
  @moduledoc """
  The graph page's provenance strip names whichever writer keeps the rows
  current, as the graph API does.

  Dev runs the event path (`graph_event_is_source`), where `IncrementalGraph`
  writes and `GraphWatcher` is never started. The page asked only
  `GraphWatcher`, so on 2026-10-12 it read "no watcher — this graph only moves
  when somebody reads it" over a graph the projector had rewired eleven minutes
  earlier, and "computed" — the newest node check — had not moved because a
  dependency change rewires edges without re-checking any node.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Requirements.GraphReport
  alias CodeMySpec.Requirements.IncrementalGraph

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    {:ok, _pid} = IncrementalGraph.ensure_projecting(ctx.scope)

    :ok =
      IncrementalGraph.settle(ctx.scope.active_project_id, [nil, ctx.scope.active_working_copy_id])

    :ok
  end

  test "on the event path the strip names the projector, idle, and when it last ran", ctx do
    strip = strip(ctx)

    assert text(strip, "graph-watcher") == "projector idle"
    refute strip =~ "no watcher"
    assert text(strip, "graph-last-pass") =~ "projector last ran"
  end

  test "the page and the graph API agree that the graph is being kept current", ctx do
    report = GraphReport.read(ctx.scope)

    assert report.watcher.watching
    assert text(strip(ctx), "graph-watcher") == "projector idle"
  end

  test "a pass the projector announces refreshes the open page", ctx do
    {:ok, view, _html} = live(ctx.conn, graph_path(ctx))

    send(view.pid, {:graph_updated, ctx.scope.active_project_id})
    render_settled(view)

    assert text(render(view), "graph-watcher") == "projector idle"
  end

  defp strip(ctx) do
    {:ok, view, _html} = live(ctx.conn, graph_path(ctx) <> "?preload=true")
    render(view)
  end

  defp graph_path(ctx), do: "/app/projects/#{ctx.project.id}/requirements/graph"

  defp text(html, test_id) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='#{test_id}']")
    |> Floki.text()
    |> String.split()
    |> Enum.join(" ")
  end
end
