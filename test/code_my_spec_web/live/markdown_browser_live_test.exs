defmodule CodeMySpecWeb.MarkdownBrowserLiveTest do
  @moduledoc """
  A doc's cross-references are clickable when they name a real file (a65ad21d).

  Driven against the real curated corpus under `priv/knowledge/` rather than a
  fixture written for the test — the whole point is a real hand-off between
  real docs (`process/product.md` -> `process/code.md`) staying in sync with
  whatever the corpus actually contains, and a fixture would only prove the
  regex works, not that today's docs still resolve.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup [:register_log_in_setup_account, :setup_active_project]

  test "a backtick path naming a real doc becomes a link to it", %{conn: conn, project: project} do
    {:ok, _live, html} =
      live(conn, ~p"/app/projects/#{project.id}/knowledge/process/product.md")

    assert html =~ ~s(href="/app/projects/#{project.id}/knowledge/process/code.md")
  end

  test "a backtick path naming nothing real stays plain text, not a dead link", %{
    conn: conn,
    project: project
  } do
    {:ok, _live, html} =
      live(conn, ~p"/app/projects/#{project.id}/knowledge/process/product.md")

    refute html =~ "knowledge/bdd/spex.md"
    assert html =~ "bdd/spex.md"
  end
end
