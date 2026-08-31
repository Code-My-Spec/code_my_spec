defmodule CodeMySpecWeb.HarnessPickerTest do
  @moduledoc """
  Choosing which working copy the files and problems pages describe.

  Story 727, criterion 739. Those rows belong to the checkout that observed
  them, so a page showing all of them shows the same path once per checkout with
  nothing saying which is which, and one checkout's failures against another's
  code. The page reads as the most recently active harness and this is how the
  operator reaches the others.

  Driven through the LiveView rather than the context because the property is
  about what the operator can see and reach, and the choice travels in the URL
  so that a link to "the files as the sprite sees them" is sendable.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.DevicesFixtures

  import Phoenix.LiveViewTest

  alias CodeMySpec.Files
  alias CodeMySpec.WorkingCopies

  setup [:register_log_in_setup_account]

  setup %{scope: scope, account: account} do
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, account_id: account.id)
    %{project: project, scope: %{scope | active_project_id: project.id, active_project: project}}
  end

  defp checkout(scope, label, paths) do
    {:ok, harness} = WorkingCopies.issue(scope, nil, label: label, device: device_fixture(scope))
    served = %{scope | active_working_copy_id: harness.id}

    Files.upsert_files(
      served,
      Enum.map(paths, &%{path: &1, role: :implementation, fingerprint: "f-#{&1}"})
    )

    harness
  end

  defp files_path(project), do: "/app/projects/#{project.id}/files"

  describe "one working copy" do
    test "no picker is shown", %{conn: conn, scope: scope, project: project} do
      checkout(scope, "the harness at /only", ["lib/a.ex"])

      {:ok, _view, html} = live(conn, files_path(project))

      refute html =~ ~s(data-test="harness-picker"),
             "a picker offering a single choice is furniture"
    end
  end

  describe "two working copies" do
    setup %{scope: scope} do
      a = checkout(scope, "the harness at /repo/main", ["lib/shared.ex", "lib/only_in_a.ex"])
      b = checkout(scope, "the harness at /repo/feature-x", ["lib/shared.ex"])
      %{a: a, b: b}
    end

    test "the page reads as the most recently active one", %{
      conn: conn,
      project: project,
      b: b
    } do
      {:ok, _view, html} = live(conn, files_path(project))

      assert html =~ ~s(data-test="harness-picker")
      assert html =~ ~s(data-test="harness-#{b.id}")

      refute html =~ "lib/only_in_a.ex",
             "b is the most recent; a file only a has is not b's to show"
    end

    test "the picker names the checkouts apart", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, files_path(project))

      assert html =~ "main"

      assert html =~ "feature-x",
             "two checkouts of one project differ by their directory, so that is " <>
               "what has to be on the button"
    end

    test "switching shows the other checkout's files", %{conn: conn, project: project, a: a} do
      {:ok, _view, html} = live(conn, files_path(project) <> "?harness=#{a.id}")

      assert html =~ "lib/only_in_a.ex",
             "this is the whole criterion — the operator can reach the other one"
    end

    test "a stale harness id falls back rather than erroring", %{conn: conn, project: project} do
      gone = Ecto.UUID.generate()

      assert {:ok, _view, html} = live(conn, files_path(project) <> "?harness=#{gone}")

      assert html =~ ~s(data-test="harness-picker"),
             "a bookmark to a checkout somebody deleted should show the current one, " <>
               "not a stack trace"
    end

    test "another project's harness id is not honoured", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      other_project = CodeMySpec.ProjectsFixtures.project_fixture(scope)
      other_scope = %{scope | active_project_id: other_project.id}
      theirs = checkout(other_scope, "the harness at /elsewhere", ["lib/theirs.ex"])

      {:ok, _view, html} = live(conn, files_path(project) <> "?harness=#{theirs.id}")

      refute html =~ "lib/theirs.ex",
             "a harness id from another project must not select rows across the boundary"
    end
  end

  describe "many working copies" do
    setup %{scope: scope} do
      # Every harness ever registered is a row, and a row is forever. This
      # project has 90 real ones, 46 of them `/T/cms_harness_<pid>` temp
      # directories left by test runs — rendered flat, that is most of a screen
      # and it grows every time anything registers.
      harnesses =
        for i <- 1..8 do
          checkout(scope, "the harness at /repo/copy-#{i}", ["lib/c#{i}.ex"])
        end

      %{harnesses: harnesses}
    end

    test "only a few are buttons; the rest are behind a count", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, files_path(project))

      assert html =~ ~s(data-test="harness-more"),
             "eight checkouts in a flat row is the growth this bounds"

      assert html =~ ">+5<" or html =~ "+5",
             "the count says how many are hidden rather than hiding that anything is"
    end

    test "the selected copy stays visible even when it is not recent", %{
      conn: conn,
      project: project,
      harnesses: harnesses
    } do
      oldest = List.first(harnesses)

      {:ok, view, _html} = live(conn, files_path(project) <> "?harness=#{oldest.id}")

      # Not merely present in the DOM — present as a *button*, outside the
      # dropdown. A picker that cannot show you what you are looking at is
      # worse than one that is too long.
      assert has_element?(
               view,
               ~s([data-test="harness-picker"] > [data-test="harness-#{oldest.id}"].btn-primary)
             ),
             "the active checkout was pushed into the overflow, so nothing on screen says which one you are reading"
    end

    test "every checkout is still reachable", %{
      conn: conn,
      project: project,
      harnesses: harnesses
    } do
      {:ok, view, _html} = live(conn, files_path(project))

      for h <- harnesses do
        assert has_element?(view, ~s([data-test="harness-#{h.id}"])),
               "bounding the picker must not make a checkout unreachable"
      end
    end
  end
end
