defmodule CodeMySpecWeb.RequirementsLive.TheGraphOpensOnAFocusedRequirementTest do
  @moduledoc """
  `?focus=` names a project gate the graph opens on, so the timeline's steps
  land on their own requirement rather than on the whole graph.
  """

  use CodeMySpecSpex.Case, async: true

  import Phoenix.LiveViewTest

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "the focused gate's node key rides on the graph element", ctx do
    project_id = ctx.scope.active_project_id

    {:ok, _view, html} =
      live(
        ctx.conn,
        "/app/projects/#{project_id}/requirements/graph?preload=true&focus=work_dispatched"
      )

    assert html =~
             ~s(data-focus="project_#{String.replace(project_id, "-", "")}_work_dispatched")
  end

  test "no focus asked for, none drawn", ctx do
    {:ok, _view, html} =
      live(
        ctx.conn,
        "/app/projects/#{ctx.scope.active_project_id}/requirements/graph?preload=true"
      )

    refute html =~ "data-focus="
  end

  test "a node picked in the graph shows its detail beside it", ctx do
    project_id = ctx.scope.active_project_id
    key = "project_#{String.replace(project_id, "-", "")}_work_dispatched"

    {:ok, view, html} =
      live(ctx.conn, "/app/projects/#{project_id}/requirements/graph?preload=true")

    assert html =~ ~s(data-select-target="#graph-page")
    refute has_element?(view, "[data-test='node-detail'][data-node]")

    render_hook(view, "select_node", %{"key" => key})

    assert has_element?(view, "[data-test='node-detail'][data-node='work_dispatched']")
  end
end
