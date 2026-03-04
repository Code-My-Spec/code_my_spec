defmodule CodeMySpecWeb.Plugs.ProjectScopeOverrideTest do
  use CodeMySpecTest.ConnCase

  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures}

  alias CodeMySpecWeb.Plugs.ProjectScopeOverride

  setup %{conn: conn} do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    conn = assign(conn, :current_scope, scope)

    %{conn: conn, scope: scope, user: user, account: account, project: project}
  end

  describe "call/2" do
    test "passes through unchanged when no X-Project-ID header", %{conn: conn, scope: scope} do
      result = ProjectScopeOverride.call(conn, [])

      assert result.assigns.current_scope.active_project_id == scope.active_project_id
      refute result.halted
    end

    test "passes through unchanged when X-Project-ID header is empty", %{
      conn: conn,
      scope: scope
    } do
      result =
        conn
        |> put_req_header("x-project-id", "")
        |> ProjectScopeOverride.call([])

      assert result.assigns.current_scope.active_project_id == scope.active_project_id
      refute result.halted
    end

    test "overrides scope when user has access to project", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      # Create a different account and project that the user also has access to
      other_account = account_fixture()
      member_fixture(user, other_account)
      other_scope = user_scope_fixture(user, other_account)
      other_project = project_fixture(other_scope)

      # Original scope points to first project
      assert scope.active_project_id != other_project.id

      result =
        conn
        |> put_req_header("x-project-id", other_project.id)
        |> ProjectScopeOverride.call([])

      refute result.halted
      assert result.assigns.current_scope.active_project_id == other_project.id
      assert result.assigns.current_scope.active_project.id == other_project.id
      assert result.assigns.current_scope.active_account_id == other_account.id
    end

    test "returns 403 when user lacks access to project", %{conn: conn} do
      # Create a project under an account the user is NOT a member of
      other_user = user_fixture()
      other_account = account_fixture()
      member_fixture(other_user, other_account)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)

      result =
        conn
        |> put_req_header("x-project-id", other_project.id)
        |> ProjectScopeOverride.call([])

      assert result.halted
      assert result.status == 403
    end

    test "returns 404 when project does not exist", %{conn: conn} do
      result =
        conn
        |> put_req_header("x-project-id", Ecto.UUID.generate())
        |> ProjectScopeOverride.call([])

      assert result.halted
      assert result.status == 404
    end

    test "passes through when no current_scope is set", %{conn: _conn} do
      conn = build_conn()

      result =
        conn
        |> put_req_header("x-project-id", Ecto.UUID.generate())
        |> ProjectScopeOverride.call([])

      refute result.halted
      refute Map.has_key?(result.assigns, :current_scope)
    end
  end
end
