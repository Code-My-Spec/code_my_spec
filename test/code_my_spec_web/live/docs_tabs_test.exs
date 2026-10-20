defmodule CodeMySpecWeb.DocsTabsTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup [:register_log_in_setup_account, :setup_active_project]

  test "docs opens on the project's tab, with CodeMySpec's guidance beside it", %{
    conn: conn,
    project: project
  } do
    {:ok, live, _html} = live(conn, ~p"/app/projects/#{project.id}/docs")

    assert has_element?(live, ~s([data-library="project_knowledge"].tab-active))

    assert has_element?(
             live,
             ~s(a[data-library="knowledge"][href="/app/projects/#{project.id}/docs/codemyspec"])
           )
  end

  test "the CodeMySpec tab lists the bundled guidance under docs", %{conn: conn, project: project} do
    {:ok, live, _html} = live(conn, ~p"/app/projects/#{project.id}/docs/codemyspec")

    assert has_element?(live, ~s([data-library="knowledge"].tab-active))
    assert has_element?(live, ~s(a[href="/app/projects/#{project.id}/docs/codemyspec/process"]))
  end

  test "the old knowledge path still opens the page", %{conn: conn, project: project} do
    {:ok, live, _html} = live(conn, ~p"/app/projects/#{project.id}/knowledge")

    assert has_element?(live, ~s([data-library="knowledge"].tab-active))
  end
end
