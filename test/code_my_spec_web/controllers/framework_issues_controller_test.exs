defmodule CodeMySpecWeb.FrameworkIssuesControllerTest do
  @moduledoc """
  Tests the deploy-key-authenticated framework issue intake. No OAuth token
  anywhere — the Bearer credential is a project deploy key, resolved via its
  blind-index hash (same flow as `WidgetSocket`), and the issue lands on the
  key's project with scope forced to `framework`.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.{UsersFixtures, ProjectsFixtures}

  alias CodeMySpec.Issues

  @deploy_key :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)

  setup %{conn: conn} do
    scope = full_scope_fixture()
    project = project_fixture(scope, %{deploy_key: @deploy_key})

    conn = put_req_header(conn, "accept", "application/json")

    {:ok, conn: conn, scope: scope, project: project}
  end

  describe "POST /api/framework/issues" do
    test "valid deploy key files a framework issue on the key's project", %{
      conn: conn,
      project: project
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@deploy_key}")
        |> post(~p"/api/framework/issues", %{
          "issue" => %{
            "title" => "Looping stop hook",
            "description" => "The stop hook re-fires forever",
            "severity" => "high"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Looping stop hook"
      assert data["scope"] == "framework"
      assert data["source"] == "cli"
      assert data["project_id"] == project.id
      assert data["account_id"] == project.account_id
    end

    test "scope in the payload cannot escape framework", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@deploy_key}")
        |> post(~p"/api/framework/issues", %{
          "issue" => %{
            "title" => "Sneaky",
            "description" => "tries to file an app issue",
            "severity" => "low",
            "scope" => "app"
          }
        })

      assert %{"data" => %{"scope" => "framework"}} = json_response(conn, 201)
    end

    test "unknown deploy key is rejected and files nothing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{String.duplicate("f", 128)}")
        |> post(~p"/api/framework/issues", %{
          "issue" => %{"title" => "Nope", "description" => "x", "severity" => "low"}
        })

      assert %{"error" => "Invalid deploy key"} = json_response(conn, 401)
      assert CodeMySpec.Repo.aggregate(Issues.Issue, :count) == 0
    end

    test "missing authorization header is rejected", %{conn: conn} do
      conn =
        post(conn, ~p"/api/framework/issues", %{
          "issue" => %{"title" => "Nope", "description" => "x", "severity" => "low"}
        })

      assert json_response(conn, 401)
    end

    test "invalid issue params return 422", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@deploy_key}")
        |> post(~p"/api/framework/issues", %{"issue" => %{"description" => "no title"}})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "missing issue param returns 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@deploy_key}")
        |> post(~p"/api/framework/issues", %{})

      assert json_response(conn, 400)
    end
  end
end
