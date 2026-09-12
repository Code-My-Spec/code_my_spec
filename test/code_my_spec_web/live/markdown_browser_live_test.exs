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

  @doc """
  Anchored on `CLAUDE.md`, which is a real file and deliberately not a doc in
  this library.

  This used to read `process/product.md` for `bdd/spex.md` — a reference to a
  doc that had been renamed away. That made the negative case a bug: QA found
  the dangling link, the doc was corrected, and a test asserting the corpus
  still contained a dead reference went red for the fix. An example that is
  wrong-by-design cannot be kept green without keeping the defect.

  A path outside the library is right-by-design instead. `CLAUDE.md` lives at
  the repo root, `Knowledge.browse/3` correctly does not find it here, and the
  doc will go on naming it for as long as it tells an agent where to write.
  """
  test "a backtick path naming nothing in this library stays plain text, not a dead link", %{
    conn: conn,
    project: project
  } do
    {:ok, _live, html} =
      live(conn, ~p"/app/projects/#{project.id}/knowledge/process/devops.md")

    refute html =~ "knowledge/CLAUDE.md"
    assert html =~ "CLAUDE.md"
  end
end
