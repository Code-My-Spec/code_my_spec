defmodule CodeMySpecWeb.DevFreshnessLiveTest do
  @moduledoc """
  The page has to name the file and say why, and it has to keep "never read"
  apart from "clean".

  Both are the claim. A freshness page that renders a verdict without naming the
  file is the project-wide boolean again with more pixels — the thing that says
  a source is stale and cannot say which file did it. And a page that folds
  unread files into a clean count is absence rendering as good news, which is
  the reading `file_analyses` exists to prevent.
  """

  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.Coverage
  alias CodeMySpec.Files
  alias CodeMySpec.WorkingCopies

  setup %{conn: conn} do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "the checkout", device: device_fixture(scope))

    %{conn: log_in_user(conn, scope.user), scope: %{scope | active_working_copy_id: copy.id}}
  end

  defp put_file(scope, path, fingerprint) do
    {_n, _} =
      Files.upsert_files(scope, [
        %{
          path: path,
          role: :implementation,
          fingerprint: fingerprint,
          mtime: DateTime.utc_now(),
          size: 10
        }
      ])

    scope |> Files.list_files() |> Enum.find(&(&1.path == path))
  end

  # The page mounts on the first project it lists, which is whichever sorts
  # first across the whole database. Driving the pickers is what a person does
  # anyway, and it makes the assertions independent of the other rows.
  defp open_on(ctx, source) do
    {:ok, view, _html} = live(ctx.conn, ~p"/dev/freshness")

    view
    |> element("form[phx-change='select_project']")
    |> render_change(%{"project" => ctx.scope.active_project_id})

    view
    |> element("form[phx-change='select_copy']")
    |> render_change(%{"copy" => ctx.scope.active_working_copy_id})

    view
    |> element("form[phx-change='select_source']")
    |> render_change(%{"source" => source})
  end

  test "a file read and then changed is named, with both contents", ctx do
    file = put_file(ctx.scope, "lib/app/drifted.ex", "read-at-this")
    Coverage.record(ctx.scope, "exunit", [{file.id, "read-at-this"}])

    # The analyzer's record now describes content the file no longer has.
    _ = put_file(ctx.scope, "lib/app/drifted.ex", "changed-since")

    html = open_on(ctx, "exunit")

    assert html =~ "lib/app/drifted.ex",
           """
           The page reports a source as behind and does not say which file did it.

           That is the project-wide boolean with more pixels. Naming the file is
           the whole reason per-file coverage exists — "why is this stale" has a
           per-file answer and the hash never did.
           """

    assert html =~ "read-at-th" and html =~ "changed-si",
           "both the content it read and the content the file has now have to be visible, or the row does not explain itself"
  end

  test "a file no analyzer has read is reported unread, not clean", ctx do
    _file = put_file(ctx.scope, "lib/app/never_looked_at.ex", "abc")

    html = open_on(ctx, "exunit")

    assert html =~ "Never read",
           "the unread section has to exist even when the stale set is empty"

    assert html =~ "lib/app/never_looked_at.ex",
           """
           A file whose role feeds this analyzer, that no run has ever covered,
           was not reported.

           `tests_passing` and `no_problems` are `count == 0`, so an unread file
           and a clean one are the same shape unless something keeps them apart.
           This page is that something.
           """

    refute html =~ "Every file whose role feeds",
           "the page claimed full coverage while a file was unread"
  end
end
