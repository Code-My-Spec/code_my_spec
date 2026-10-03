defmodule CodeMySpecWeb.RequirementsGraphControllerTest do
  @moduledoc """
  `GET /api/projects/:project_id/requirements/graph` — the local app's graph
  read, behind a credential instead of a seat on the machine.
  """

  # The spex case for its project setup: a configured project with a graph
  # watcher computing it, which is the state the local route is read in.
  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Projects

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    key = "dk_graph_#{System.unique_integer([:positive])}"
    {:ok, project} = Projects.update_project(ctx.scope, ctx.project, %{deploy_key: key})

    %{project: project, deploy_key: key, conn: build_conn()}
  end

  describe "with the project's deploy key" do
    test "serves the same payload the local app serves for that project", ctx do
      cloud =
        ctx.conn
        |> bearer(ctx.deploy_key)
        |> cloud_get(cloud_path(ctx.project))
        |> json_response(200)

      local = local_graph(ctx.project)

      assert cloud["nodes"] != [], "the premise is a computed graph; this one is empty"
      assert Map.keys(cloud) == Map.keys(local)
      assert cloud["nodes"] == local["nodes"]
      assert cloud["edges"] == local["edges"]
      assert cloud["computed_at"] == local["computed_at"]
      assert cloud["served_from"] == "cache"
    end

    test "names a working copy with ?working_copy, as the local route does", ctx do
      copy_id = Ecto.UUID.generate()

      body =
        ctx.conn
        |> bearer(ctx.deploy_key)
        |> cloud_get(cloud_path(ctx.project) <> "?working_copy=#{copy_id}&settle=false")
        |> json_response(200)

      assert body == local_graph(ctx.project, "?working_copy=#{copy_id}&settle=false")
    end

    test "does not reach another project", ctx do
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)

      other =
        project_fixture(user_scope_fixture(other_user, other_account),
          account_id: other_account.id
        )

      conn = ctx.conn |> bearer(ctx.deploy_key) |> cloud_get(cloud_path(other))

      assert json_response(conn, 403)["error"] =~ "does not reach"
    end
  end

  describe "with an OAuth token" do
    test "a member reads the graph", ctx do
      conn = ctx.conn |> bearer(access_token(ctx.user)) |> cloud_get(cloud_path(ctx.project))

      assert json_response(conn, 200)["nodes"] != []
    end

    test "someone outside the account is refused", ctx do
      stranger = user_fixture()

      conn = ctx.conn |> bearer(access_token(stranger)) |> cloud_get(cloud_path(ctx.project))

      assert json_response(conn, 403)
    end
  end

  describe "without a credential" do
    test "is refused before anything is read", ctx do
      conn = cloud_get(ctx.conn, cloud_path(ctx.project))

      assert conn.status == 401
      refute conn.resp_body =~ "nodes"
    end

    test "a key nobody issued is refused", ctx do
      conn = ctx.conn |> bearer("dk_nobody_issued_this") |> cloud_get(cloud_path(ctx.project))

      assert conn.status == 401
    end
  end

  test "an unknown project is not found", ctx do
    conn =
      ctx.conn
      |> bearer(access_token(ctx.user))
      |> cloud_get(cloud_path(%{id: Ecto.UUID.generate()}))

    assert json_response(conn, 404)
  end

  defp cloud_get(conn, path), do: dispatch(conn, CodeMySpecWeb.Endpoint, :get, path)

  defp cloud_path(project), do: "/api/projects/#{project.id}/requirements/graph"

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp local_graph(project, query \\ "") do
    build_conn()
    |> dispatch(
      CodeMySpecLocalWeb.Endpoint,
      :get,
      "/api/projects/#{project.name}/requirements/graph" <> query
    )
    |> json_response(200)
  end

  defp access_token(user) do
    value = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, [app]} =
      CodeMySpec.Repo.insert_all(
        "oauth_applications",
        [
          %{
            name: "Graph route test",
            uid: "graph-route-#{System.unique_integer([:positive])}",
            secret: "secret-#{System.unique_integer([:positive])}",
            redirect_uri: "https://example.com/callback",
            scopes: "read write",
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    {1, _} =
      CodeMySpec.Repo.insert_all("oauth_access_tokens", [
        %{
          token: value,
          resource_owner_id: user.id,
          application_id: app.id,
          scopes: "read write",
          expires_in: 7200,
          inserted_at: now,
          updated_at: now
        }
      ])

    value
  end
end
