defmodule CodeMySpecWeb.SourceGitControllerTest do
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.OauthFixtures

  alias CodeMySpec.Projects
  alias CodeMySpecWeb.SourceGitController

  defmodule RawAdapter do
    def run(request), do: Process.get(:source_git_raw_adapter).(request)
  end

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

  test "a device-token member without GitHub clones code and docs with an account member's connection",
       context do
    member = user_fixture()
    account = context.scope.active_account
    member_fixture(member, account)
    token = device_token_for(member)

    Req.Test.stub(SourceGitController, fn upstream ->
      assert Plug.Conn.get_req_header(upstream, "authorization") ==
               ["Basic " <> Base.encode64("x-access-token:" <> context.integration.access_token)]

      assert upstream.request_path in [
               "/example/private-code.git/info/refs",
               "/example/private-docs.git/info/refs",
               "/example/private-code.git/git-upload-pack",
               "/example/private-docs.git/git-upload-pack"
             ]

      response_bodies = %{"GET" => <<0, 255, 1, 2>>, "POST" => <<255, 0, 4>>}
      Plug.Conn.resp(upstream, 200, Map.fetch!(response_bodies, upstream.method))
    end)

    for kind <- ["code", "docs"] do
      path = "/api/source/#{context.project.id}/#{kind}"

      refs =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(path <> "/info/refs?service=git-upload-pack")

      assert refs.status == 200
      assert refs.resp_body == <<0, 255, 1, 2>>

      pack =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/x-git-upload-pack-request")
        |> post(path <> "/git-upload-pack", <<0, 255, 3>>)

      assert pack.status == 200
      assert pack.resp_body == <<255, 0, 4>>
    end
  end

  test "forwards Git protocol and compressed upload-pack bytes unchanged", context do
    compressed_request = :zlib.gzip(<<0, 255, 3, 4>>)
    compressed_response = :zlib.gzip(<<255, 0, 4, 5>>)

    previous = Application.get_env(:code_my_spec, SourceGitController)
    on_exit(fn -> Application.put_env(:code_my_spec, SourceGitController, previous) end)

    adapter = fn request ->
      assert Req.Request.get_header(request, "git-protocol") == ["version=2"]
      assert Req.Request.get_header(request, "accept") == ["application/x-git-upload-pack-result"]
      assert Req.Request.get_header(request, "content-encoding") == ["gzip"]
      assert request.body == compressed_request

      response = %Req.Response{
        status: 200,
        headers:
          Req.Fields.new([
            {"content-type", "application/x-git-upload-pack-result"},
            {"content-encoding", "gzip"}
          ]),
        body: compressed_response
      }

      {request, response}
    end

    Process.put(:source_git_raw_adapter, adapter)
    Application.put_env(:code_my_spec, SourceGitController, adapter: RawAdapter)

    conn =
      Plug.Test.conn(:post, "/", compressed_request)
      |> Plug.Conn.put_req_header("git-protocol", "version=2")
      |> Plug.Conn.put_req_header("accept", "application/x-git-upload-pack-result")
      |> Plug.Conn.put_req_header("content-encoding", "gzip")
      |> Plug.Conn.assign(:current_scope, context.scope)

    response =
      SourceGitController.upload_pack(conn, %{
        "project_id" => context.project.id,
        "kind" => "code"
      })

    assert response.status == 200
    assert response.resp_body == compressed_response
    assert Plug.Conn.get_resp_header(response, "content-encoding") == ["gzip"]
  end

  test "a device-token non-member cannot reach the project's source", context do
    token = user_fixture() |> device_token_for()

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/source/#{context.project.id}/code/info/refs?service=git-upload-pack")

    assert response.status == 404
  end

  defp device_token_for(user) do
    client = oauth_application_fixture()
    {:ok, grant} = CodeMySpec.Oauth.request_device_code(client.uid, Ecto.UUID.generate())
    assert {:ok, _} = CodeMySpec.Oauth.decide_device_grant(grant, user, :approve)

    response =
      post(build_conn(), "/oauth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" => grant.device_code,
        "client_id" => client.uid
      })

    assert %{"access_token" => token} = json_response(response, 200)
    token
  end
end
