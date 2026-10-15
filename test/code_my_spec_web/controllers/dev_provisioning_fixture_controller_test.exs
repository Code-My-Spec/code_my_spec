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

  test "prepares an isolated agent runtime without exposing its token", %{
    conn: conn,
    credentials: credentials
  } do
    created = conn |> post("/dev/provisioning-fixtures", credentials) |> json_response(200)
    path = "/dev/provisioning-fixtures/#{created["project_id"]}/prepare-agent"

    prepared =
      build_conn() |> Map.put(:host, "localhost") |> post(path, credentials) |> json_response(200)

    refute Map.has_key?(prepared, "token")
    runtime = prepared["runtime_path"] |> File.read!() |> Jason.decode!()
    assert runtime["fixture"] == "story-963"
    assert runtime["project_id"] == created["project_id"]
    assert runtime["working_copy_id"] == prepared["working_copy_id"]
    token = ExOauth2Provider.AccessTokens.get_by_token(runtime["token"], otp_app: :code_my_spec)
    assert token
    assert ExOauth2Provider.AccessTokens.is_accessible?(token)
    # 12h (c79fb8f9): this token bypasses CmsHarness.Token's own refresh (it
    # is read straight as :harness_token), so it is the only credential the
    # fixture's dedicated harness gets for the whole QA session.
    assert token.expires_in == 12 * 60 * 60
    assert Bitwise.band(File.stat!(prepared["runtime_path"]).mode, 0o777) == 0o600
    assert {:ok, copy} = CodeMySpec.WorkingCopies.fetch(prepared["working_copy_id"])
    assert copy.project_id == created["project_id"]
    assert copy.root == prepared["root"]
    assert copy.main

    assert build_conn()
           |> Map.put(:host, "localhost")
           |> post(path, credentials)
           |> json_response(422)
  end

  test "refuses agent preparation for ordinary projects", %{
    scope: scope,
    credentials: credentials
  } do
    path = "/dev/provisioning-fixtures/#{scope.active_project_id}/prepare-agent"

    assert build_conn()
           |> Map.put(:host, "localhost")
           |> post(path, credentials)
           |> json_response(422)
  end

  test "refuses starting an agent on an ordinary project or another project's copy", %{
    scope: scope,
    credentials: credentials
  } do
    ordinary = "/dev/provisioning-fixtures/#{scope.active_project_id}/start-agent"
    params = Map.put(credentials, :working_copy_id, scope.active_working_copy_id)
    assert build_conn() |> post(ordinary, params) |> json_response(422)

    created =
      build_conn() |> post("/dev/provisioning-fixtures", credentials) |> json_response(200)

    fixture = "/dev/provisioning-fixtures/#{created["project_id"]}/start-agent"
    assert build_conn() |> post(fixture, params) |> json_response(422)
  end

  test "refuses preparing a runtime for a nonlocal server", %{credentials: credentials} do
    created =
      build_conn() |> post("/dev/provisioning-fixtures", credentials) |> json_response(200)

    path = "/dev/provisioning-fixtures/#{created["project_id"]}/prepare-agent"

    assert build_conn()
           |> Map.put(:host, "example.com")
           |> post(path, credentials)
           |> json_response(422)
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
