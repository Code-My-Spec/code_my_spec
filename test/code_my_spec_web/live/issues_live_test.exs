defmodule CodeMySpecWeb.IssuesLiveTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.IssuesFixtures
  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.DevicesFixtures
  alias CodeMySpec.Issues
  alias CodeMySpec.WorkingCopies

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
      {:ok, live_view, html} =
        live(
          conn,
          ~p"/app/projects/#{project.id}/issues?#{[severity: ~w(critical high medium low info)]}"
        )

      # Both visible initially
      assert html =~ incoming.title
      assert html =~ accepted.title

      # Filter to accepted only
      html =
        live_view
        |> form("form[phx-change='filter']", %{status: ["accepted"]})
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
        |> form("form[phx-change='filter']", %{severity: ["critical"]})
        |> render_change()

      assert html =~ accepted.title
      refute html =~ incoming.title
    end
  end

  defp created_ago(issue, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    CodeMySpec.Repo.update_all(
      from(i in Issues.Issue, where: i.id == ^issue.id),
      set: [inserted_at: at]
    )
  end

  defp listed_ids(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#issues [id^='issue-']")
    |> Enum.flat_map(&Floki.attribute(&1, "id"))
  end

  describe "Index order and closed issues" do
    setup %{scope: scope} do
      old_incoming = issue_fixture(scope, %{title: "Old incoming"})
      new_incoming = issue_fixture(scope, %{title: "New incoming"})
      accepted = issue_fixture(scope, %{title: "Accepted one", status: :accepted})
      dismissed = issue_fixture(scope, %{title: "Dismissed one", status: :dismissed})
      resolved = issue_fixture(scope, %{title: "Resolved one", status: :resolved})

      created_ago(old_incoming, 7200)
      created_ago(new_incoming, 60)
      created_ago(accepted, 10)

      %{
        old_incoming: old_incoming,
        new_incoming: new_incoming,
        accepted: accepted,
        dismissed: dismissed,
        resolved: resolved
      }
    end

    test "incoming first, then accepted, newest first; closed hidden", ctx do
      {:ok, view, html} = live(ctx.conn, ~p"/app/projects/#{ctx.project.id}/issues")

      assert listed_ids(html) ==
               Enum.map([ctx.new_incoming, ctx.old_incoming, ctx.accepted], &"issue-#{&1.id}")

      assert has_element?(view, "[data-test='issue-group'][data-status='incoming']")
      assert has_element?(view, "[data-test='issue-group'][data-status='accepted']")
      refute html =~ ctx.dismissed.title
      refute html =~ ctx.resolved.title
    end

    test "the status filter shows resolved and dismissed", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/app/projects/#{ctx.project.id}/issues")

      html =
        view
        |> form("form[phx-change='filter']", %{status: ~w(incoming accepted resolved dismissed)})
        |> render_change()

      assert html =~ ctx.dismissed.title
      assert html =~ ctx.resolved.title

      assert_patch(
        view,
        ~p"/app/projects/#{ctx.project.id}/issues?#{[status: ~w(incoming accepted resolved dismissed), severity: ~w(high medium)]}"
      )

      ids = listed_ids(html)

      assert Enum.take(ids, 3) ==
               Enum.map([ctx.new_incoming, ctx.old_incoming, ctx.accepted], &"issue-#{&1.id}")

      html =
        view
        |> form("form[phx-change='filter']", %{status: ["resolved"]})
        |> render_change()

      assert listed_ids(html) == ["issue-#{ctx.resolved.id}"]
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

    test "names a linked story by its number and links to it", %{
      project: project,
      conn: conn,
      scope: scope
    } do
      # A number no id reaches, so rendering the id instead could not pass
      # (883a14a5: two filler stories only made them differ by luck).
      story =
        CodeMySpec.StoriesFixtures.story_fixture(scope, %{
          title: "Linked story",
          number: 7_000_000 + System.unique_integer([:positive])
        })

      assert story.id != story.number
      issue = issue_fixture(scope, %{title: "Linked bug", story_id: story.id})

      {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      assert html =~ "Story #{story.number} — Linked story"
      assert html =~ "/stories/#{story.number}\""
      refute html =~ "##{story.id}"
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

    test "assigning from the page confirms success and shows the current assignment", %{
      project: project,
      conn: conn,
      scope: scope,
      issue: issue
    } do
      {:ok, issue} = Issues.accept_issue(scope, issue)

      {:ok, copy} = WorkingCopies.issue(scope, nil, device: DevicesFixtures.device_fixture(scope))

      {:ok, _coder} =
        AgentsRepository.create_agent(scope, %{
          engine: :alloy,
          provider: "zai",
          working_copy: "/tmp/show-spex-copy",
          role: :coding,
          status: :running,
          working_copy_id: copy.id
        })

      {:ok, live_view, html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")
      refute html =~ "Assigned to"

      html =
        live_view
        |> form("[data-test='issue-assignment-form']", %{"working_copy_id" => copy.id})
        |> render_submit()

      assert html =~ "Issue assigned."
      assert html =~ "Assigned to"
      assert html =~ WorkingCopies.display_name(copy)

      {:ok, _live, reloaded_html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")
      assert reloaded_html =~ "Assigned to"
      assert reloaded_html =~ WorkingCopies.display_name(copy)
    end

    test "reassigning from the page moves the issue to the new working copy", %{
      project: project,
      conn: conn,
      scope: scope,
      issue: issue
    } do
      {:ok, issue} = Issues.accept_issue(scope, issue)

      {:ok, copy_a} =
        WorkingCopies.issue(scope, nil, device: DevicesFixtures.device_fixture(scope))

      {:ok, _} =
        AgentsRepository.create_agent(scope, %{
          engine: :alloy,
          provider: "zai",
          working_copy: "/tmp/reassign-a",
          role: :coding,
          status: :running,
          working_copy_id: copy_a.id
        })

      {:ok, copy_b} =
        WorkingCopies.issue(scope, nil, device: DevicesFixtures.device_fixture(scope))

      {:ok, _} =
        AgentsRepository.create_agent(scope, %{
          engine: :alloy,
          provider: "zai",
          working_copy: "/tmp/reassign-b",
          role: :coding,
          status: :running,
          working_copy_id: copy_b.id
        })

      {:ok, live_view, _html} = live(conn, ~p"/app/projects/#{project.id}/issues/#{issue.id}")

      html_a =
        live_view
        |> form("[data-test='issue-assignment-form']", %{"working_copy_id" => copy_a.id})
        |> render_submit()

      assert html_a =~ "Issue assigned."
      assert html_a =~ WorkingCopies.display_name(copy_a)

      html_b =
        live_view
        |> form("[data-test='issue-assignment-form']", %{"working_copy_id" => copy_b.id})
        |> render_submit()

      assert html_b =~ "Issue assigned."
      assert html_b =~ WorkingCopies.display_name(copy_b)

      assert Issues.get_issue!(scope, issue.id).assigned_working_copy_id == copy_b.id
      refute Issues.get_issue!(scope, issue.id).assigned_working_copy_id == copy_a.id
    end
  end
end
