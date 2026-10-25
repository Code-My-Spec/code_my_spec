defmodule CodeMySpecWeb.DevProvisioningFixtureControllerTest do
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures

  alias ClientUtils.Harness.Onboarding
  alias CodeMySpec.{AgentAttachments, Projects, UserPreferences, Users}

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

  # Its headers alone got 401 from /mcp/harness, and a copy's cloned database
  # held only the seed user's expired tokens: QA of 1148 and 1157 stalled.
  test "qa-agents headers carry a token /mcp/harness accepts", %{credentials: credentials} do
    start_supervised!({CodeMySpecWeb.QaEnvironments, root: File.cwd!()})

    %{"agents" => [%{"headers" => headers}]} =
      build_conn()
      |> post("/dev/qa-agents", Map.put(credentials, :roles, ["qa"]))
      |> json_response(200)

    assert "Bearer " <> token = headers["Authorization"]
    assert ExOauth2Provider.AccessTokens.get_by_token(token, otp_app: :code_my_spec)

    # The check `/mcp/harness`'s `:mcp_protected` pipeline makes.
    conn =
      headers
      |> Enum.reduce(build_conn(), fn {k, v}, conn ->
        put_req_header(conn, String.downcase(k), v)
      end)
      |> CodeMySpecWeb.UserAuth.require_oauth_token([])

    refute conn.halted, "the token was refused (#{conn.status})"
    assert conn.assigns.current_scope.user.email == credentials.email
  end

  # 1148's QA could not tell an offline device or a foreign copy id apart from
  # anything else: the fixture made neither.
  test "attachment fixtures give Main an offline copy and a copy it may not attach", %{
    scope: scope,
    credentials: credentials
  } do
    start_supervised!({CodeMySpecWeb.QaEnvironments, root: File.cwd!()})

    %{"project_id" => project_id, "agents" => [%{"agent_id" => main_id}]} =
      reply =
      build_conn()
      |> post(
        "/dev/qa-agents",
        Map.merge(credentials, %{roles: ["main"], attachment_fixtures: true})
      )
      |> json_response(200)

    %{"online" => online, "offline" => offline, "unauthorized_working_copy_id" => foreign_id} =
      reply["attachment_fixtures"]

    on_exit(fn -> File.rm_rf(Path.dirname(Path.dirname(offline["root"]))) end)

    # Each on a device of its own, which a harness serving it presents.
    assert [_, _] = online
    assert length(Enum.uniq(Enum.map([offline | online], & &1["device_id"]))) == 3

    for copy <- [offline | online] do
      assert File.read!(Path.join(copy["root"], ".cms_harness.json")) =~ copy["working_copy_id"]
      # What Codex Cloud's readiness check and the harness ask of a copy.
      assert %{onboarded: true} = Onboarding.check(copy["root"])

      assert copy["root"] |> Path.join(".claude/settings.local.json") |> File.read!() =~
               copy["working_copy_id"]

      assert %{"device_id" => copy["device_id"]} ==
               copy["root"]
               |> Path.dirname()
               |> Path.join("device.json")
               |> File.read!()
               |> Jason.decode!()
    end

    for %{"root" => root, "harness" => harness} <- online do
      assert harness["command"] =~ "CMS_PROJECT_DIR=#{root} "
      assert harness["command"] =~ "CMS_HARNESS_PORT=#{harness["port"]} "
    end

    main = %{scope | active_project_id: project_id}

    assert {:error, :harness_unreachable} =
             AgentAttachments.connect(main, main_id, offline["working_copy_id"])

    assert {:error, :working_copy_not_found} =
             AgentAttachments.connect(main, main_id, foreign_id)
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
