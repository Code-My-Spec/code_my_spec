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

  describe "framework issue create bypass" do
    setup %{user: user} do
      # The CodeMySpec project lives under an account the user is NOT a member of.
      cms_owner = user_fixture()
      cms_account = account_fixture()
      member_fixture(cms_owner, cms_account)
      cms_scope = user_scope_fixture(cms_owner, cms_account)
      cms_project = project_fixture(cms_scope)

      # Sanity: the filing user really has no access to the CodeMySpec account.
      refute CodeMySpec.Accounts.user_has_account_access?(
               user_scope_fixture(user, account_fixture()),
               cms_account.id
             )

      prev = Application.get_env(:code_my_spec, :code_my_spec_project_id)
      Application.put_env(:code_my_spec, :code_my_spec_project_id, cms_project.id)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:code_my_spec, :code_my_spec_project_id, prev),
          else: Application.delete_env(:code_my_spec, :code_my_spec_project_id)
      end)

      %{cms_project: cms_project, cms_account: cms_account}
    end

    test "allows a framework issue create for a user without account access", %{
      conn: conn,
      cms_project: cms_project,
      cms_account: cms_account
    } do
      result =
        %{
          conn
          | method: "POST",
            path_info: ["api", "issues"],
            params: %{"issue" => %{"scope" => "framework"}}
        }
        |> put_req_header("x-project-id", cms_project.id)
        |> ProjectScopeOverride.call([])

      refute result.halted
      assert result.assigns.current_scope.active_project_id == cms_project.id
      assert result.assigns.current_scope.active_account_id == cms_account.id
    end

    test "still 403s for a non-framework issue create on the CodeMySpec project", %{
      conn: conn,
      cms_project: cms_project
    } do
      result =
        %{
          conn
          | method: "POST",
            path_info: ["api", "issues"],
            params: %{"issue" => %{"scope" => "app"}}
        }
        |> put_req_header("x-project-id", cms_project.id)
        |> ProjectScopeOverride.call([])

      assert result.halted
      assert result.status == 403
    end

    test "still 403s for framework scope on a different resource path", %{
      conn: conn,
      cms_project: cms_project
    } do
      result =
        %{
          conn
          | method: "POST",
            path_info: ["api", "stories"],
            params: %{"issue" => %{"scope" => "framework"}}
        }
        |> put_req_header("x-project-id", cms_project.id)
        |> ProjectScopeOverride.call([])

      assert result.halted
      assert result.status == 403
    end
  end
end
