defmodule CodeMySpecWeb.IssuesLiveTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.Issues

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp create_issue(%{scope: scope}) do
    issue =
      issue_fixture(scope, %{title: "Test bug", severity: :high, description: "Something broke"})

    %{issue: issue}
  end

  defp create_issues(%{scope: scope}) do
    incoming =
      issue_fixture(scope, %{title: "Incoming issue", severity: :medium, status: :incoming})

    accepted = issue_fixture(scope, %{title: "Accepted issue", severity: :critical})
    {:ok, accepted} = Issues.accept_issue(scope, accepted)

    %{incoming: incoming, accepted: accepted}
  end

  describe "Index" do
    setup [:create_issue]

    test "lists all issues", %{project: project, conn: conn, issue: issue} do
      {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/issues")

      assert html =~ "Issues"
      assert html =~ issue.title
    end

    test "displays severity and status badges", %{project: project, conn: conn, issue: issue} do
      {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/issues")

      assert html =~ to_string(issue.severity)
      assert html =~ to_string(issue.status)
    end

    test "navigates to issue show page", %{project: project, conn: conn, issue: issue} do
      {:ok, live_view, _html} = live(conn, ~p"/app/projects/#{project.id}/issues")

      assert live_view
             |> element("#issue-#{issue.id}")
             |> render_click()

      assert_redirect(live_view, ~p"/app/projects/#{project.id}/issues/#{issue.id}")
    end
  end

  describe "Index filtering" do
    setup [:create_issues]

    test "filters by status", %{
      project: project,
      conn: conn,
      incoming: incoming,
      accepted: accepted
    } do
      {:ok, live_view, html} = live(conn, ~p"/app/projects/#{project.id}/issues")

      # Both visible initially
      assert html =~ incoming.title
      assert html =~ accepted.title

      # Filter to accepted only
      html =
        live_view
        |> form("form[phx-change='filter']", %{status: "accepted"})
        |> render_change()

      assert html =~ accepted.title
      refute html =~ incoming.title
    end

    test "filters by severity", %{
      project: project,
      conn: conn,
      incoming: incoming,
      accepted: accepted
    } do
      {:ok, live_view, _html} = live(conn, ~p"/app/projects/#{project.id}/issues")

      # Filter to critical only
      html =
        live_view
        |> form("form[phx-change='filter']", %{severity: "critical"})
        |> render_change()

      assert html =~ accepted.title
      refute html =~ incoming.title
    end
  end

  describe "Show" do
    setup [:create_issue]

    test "displays issue details", %{project: project, conn: conn, issue: issue} do
      {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      assert html =~ issue.title
      assert html =~ issue.description
      assert html =~ to_string(issue.severity)
      assert html =~ to_string(issue.status)
    end

    test "shows accept and dismiss actions for incoming issue", %{
      project: project,
      conn: conn,
      issue: issue
    } do
      {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      assert html =~ "Accept"
      assert html =~ "Dismiss"
      refute html =~ "Resolve"
    end

    test "accepts an incoming issue", %{project: project, conn: conn, issue: issue} do
      {:ok, live_view, _html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      html =
        live_view
        |> element("button", "Accept")
        |> render_click()

      assert html =~ "Issue accepted"
      assert html =~ "accepted"
      refute html =~ "Accept"
      assert html =~ "Resolve"
    end

    test "dismisses an incoming issue with reason", %{project: project, conn: conn, issue: issue} do
      {:ok, live_view, _html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      # Open dismiss form
      live_view
      |> element("button", "Dismiss")
      |> render_click()

      # Submit with reason
      html =
        live_view
        |> form("form[phx-submit='dismiss']", %{reason: "Not a real bug"})
        |> render_submit()

      assert html =~ "Issue dismissed"
      assert html =~ "dismissed"
    end

    test "resolves an accepted issue", %{project: project, conn: conn, scope: scope, issue: issue} do
      {:ok, issue} = Issues.accept_issue(scope, issue)

      {:ok, live_view, html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      assert html =~ "Resolve"

      # Open resolve form
      live_view
      |> element("button", "Resolve")
      |> render_click()

      # Submit with resolution
      html =
        live_view
        |> form("form[phx-submit='resolve']", %{resolution: "Fixed in commit abc123"})
        |> render_submit()

      assert html =~ "Issue resolved"
      assert html =~ "resolved"
    end

    test "shows no actions for terminal states", %{
      project: project,
      conn: conn,
      scope: scope,
      issue: issue
    } do
      {:ok, issue} = Issues.accept_issue(scope, issue)
      {:ok, issue} = Issues.resolve_issue(scope, issue, "Done")

      {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      refute html =~ "Accept"
      refute html =~ "Dismiss"
      refute html =~ "Resolve"
    end

    test "back button navigates to index", %{project: project, conn: conn, issue: issue} do
      {:ok, live_view, _html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      assert live_view
             |> element("a[href='/app/projects/#{project.id}/issues']")
             |> has_element?()
    end
  end
end
