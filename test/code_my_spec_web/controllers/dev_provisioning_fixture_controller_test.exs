defmodule CodeMySpecWeb.DevProvisioningFixtureControllerTest do
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{Projects, UserPreferences, Users}

  setup do
    scope = full_scope_fixture()
    password = "qa-fixture-controller-password"

    {:ok, _} =
      Users.update_user_password(scope.user, %{
        password: password,
        password_confirmation: password
      })

    {:ok, _} =
      UserPreferences.create_user_preferences(scope, %{active_account_id: scope.active_account_id})

    %{scope: scope, credentials: %{email: scope.user.email, password: password}}
  end

  test "creates a fresh disposable project and exposes provider controls", %{
    conn: conn,
    scope: scope,
    credentials: credentials
  } do
    created = conn |> post("/dev/provisioning-fixtures", credentials) |> json_response(200)
    assert created["simulated"] == true
    assert created["account_id"] == scope.active_account_id
    assert {:ok, project} = Projects.get_project(scope, created["project_id"])
    assert project.domain == "setup-qa.invalid"
    path = "/dev/provisioning-fixtures/#{project.id}"
    baseline = build_conn() |> post(path <> "/inspect", credentials) |> json_response(200)
    assert baseline["resources"] == []
    assert baseline["events"] == []
    params = Map.merge(credentials, %{step: "domain", action: "register"})
    registered = build_conn() |> post(path <> "/control", params) |> json_response(200)
    assert [%{"kind" => "domain"}] = registered["resources"]
  end

  test "refuses missing credentials", %{conn: conn} do
    assert conn |> post("/dev/provisioning-fixtures", %{}) |> json_response(422)
  end

  test "refuses an ordinary project and a project outside the account", %{
    scope: scope,
    credentials: credentials
  } do
    own_path = "/dev/provisioning-fixtures/#{scope.active_project_id}/control"
    params = Map.merge(credentials, %{step: "server", action: "delete"})
    assert build_conn() |> post(own_path, params) |> json_response(422)
    other = full_scope_fixture()
    other_path = "/dev/provisioning-fixtures/#{other.active_project_id}/inspect"
    assert build_conn() |> post(other_path, credentials) |> json_response(422)
  end
end
