defmodule CodeMySpecWeb.PortableHostTest do
  @moduledoc """
  The seam `SessionsLiveTest` points at: a bad project id is the host's to
  refuse, so every portable view can be written as though the project it was
  handed is the one in the URL.

  Before `d500df3b` the host assigned `scope_error` and continued. Only the
  StoryLive views render that assign, so Sessions, Files, Configuration and Qa
  fell through to a clause still reading `current_scope` — the *previous*
  project — and rendered its data under the requested project's URL. The
  failure mode was a page that looked right and was about something else.
  """
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures

  setup [:register_and_log_in_user, :setup_active_account]

  defp someone_elses_project(_context) do
    other_user = user_fixture()
    other_account = account_with_owner_fixture(other_user)
    other_scope = user_scope_fixture(other_user, other_account)

    %{theirs: project_fixture(other_scope, account_id: other_account.id)}
  end

  describe "a project id the signed-in user cannot see" do
    setup [:someone_elses_project]

    test "is refused rather than answered with another project's data", %{
      conn: conn,
      theirs: theirs
    } do
      assert {:error, {:live_redirect, %{to: "/app/projects", flash: flash}}} =
               live(conn, ~p"/app/projects/#{theirs.id}/sessions")

      assert flash["error"] =~ "not in the account you are in"
    end

    test "is refused the same way on every project-scoped route", %{conn: conn, theirs: theirs} do
      routes = [
        ~p"/app/projects/#{theirs.id}/sessions",
        ~p"/app/projects/#{theirs.id}/files",
        ~p"/app/projects/#{theirs.id}/configuration",
        ~p"/app/projects/#{theirs.id}/qa",
        ~p"/app/projects/#{theirs.id}/issues",
        ~p"/app/projects/#{theirs.id}/problems"
      ]

      for path <- routes do
        assert {:error, {:live_redirect, %{to: "/app/projects"}}} = live(conn, path),
               "#{path} did not refuse a project outside the active account"
      end
    end

    test "refuses an id that is not a uuid at all", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/app/projects"}}} =
               live(conn, ~p"/app/projects/not-a-uuid/sessions")
    end
  end

  describe "a project the user can see" do
    test "still resolves from the URL, not the stored active project", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      mine = project_fixture(scope, account_id: account.id)

      assert {:ok, _view, _html} = live(conn, ~p"/app/projects/#{mine.id}/sessions")
    end
  end
end
