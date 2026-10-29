defmodule CodeMySpecWeb.SourceGitControllerTest do
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.Projects
  alias CodeMySpecWeb.SourceGitController

  setup do
    scope = full_scope_fixture()
    project = scope.active_project

    {:ok, project} =
      Projects.update_project(scope, project, %{
        code_repo: "https://github.com/example/private-code.git",
        docs_repo: "git@github.com:example/private-docs.git"
      })

    integration = github_integration_fixture(scope.user)

    %{scope: scope, project: project, integration: integration}
  end

  test "advertises an account project's private code without exposing the GitHub token",
       context do
    Req.Test.stub(SourceGitController, fn upstream ->
      assert upstream.request_path == "/example/private-code.git/info/refs"
      assert upstream.query_string == "service=git-upload-pack"

      assert Plug.Conn.get_req_header(upstream, "authorization") ==
               ["Basic " <> Base.encode64("x-access-token:" <> context.integration.access_token)]

      Plug.Conn.resp(upstream, 200, <<0, 255, 1, 2>>)
    end)

    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.assign(:current_scope, context.scope)

    response =
      SourceGitController.refs(conn, %{
        "project_id" => context.project.id,
        "kind" => "code",
        "service" => "git-upload-pack"
      })

    assert response.status == 200
    assert response.resp_body == <<0, 255, 1, 2>>
    refute response.resp_body =~ context.integration.access_token
  end

  test "proxies a member project's code when the device has no active account", context do
    Req.Test.stub(SourceGitController, fn upstream ->
      assert upstream.request_path == "/example/private-code.git/info/refs"
      Plug.Conn.resp(upstream, 200, <<0, 255, 1, 2>>)
    end)

    scope = %{
      context.scope
      | active_account_id: nil,
        active_account: nil,
        active_project_id: nil,
        active_project: nil
    }

    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.assign(:current_scope, scope)

    response =
      SourceGitController.refs(conn, %{
        "project_id" => context.project.id,
        "kind" => "code",
        "service" => "git-upload-pack"
      })

    assert response.status == 200
    assert response.resp_body == <<0, 255, 1, 2>>
  end

  test "does not proxy another account's project", context do
    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.assign(:current_scope, context.scope)

    response =
      SourceGitController.refs(conn, %{
        "project_id" => Ecto.UUID.generate(),
        "kind" => "code",
        "service" => "git-upload-pack"
      })

    assert response.status == 404
  end

  test "refuses Git write service", context do
    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.assign(:current_scope, context.scope)

    response =
      SourceGitController.refs(conn, %{
        "project_id" => context.project.id,
        "kind" => "code",
        "service" => "git-receive-pack"
      })

    assert response.status == 400
  end

  test "proxies the binary upload pack request to the configured docs repo", context do
    Req.Test.stub(SourceGitController, fn upstream ->
      assert upstream.method == "POST"
      assert upstream.request_path == "/example/private-docs.git/git-upload-pack"
      assert {:ok, <<0, 255, 3>>, upstream} = Plug.Conn.read_body(upstream)
      Plug.Conn.resp(upstream, 200, <<255, 0, 4>>)
    end)

    conn =
      Plug.Test.conn(:post, "/", <<0, 255, 3>>)
      |> Plug.Conn.assign(:current_scope, context.scope)

    response =
      SourceGitController.upload_pack(conn, %{
        "project_id" => context.project.id,
        "kind" => "docs"
      })

    assert response.status == 200
    assert response.resp_body == <<255, 0, 4>>
  end
end
