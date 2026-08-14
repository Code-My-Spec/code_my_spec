defmodule CodeMySpecWeb.WidgetUsersControllerTest do
  @moduledoc """
  Tests the deploy-key-authenticated external-user upsert. No OAuth token
  anywhere — the Bearer credential is a project deploy key, resolved via its
  blind-index hash (same flow as `WidgetSocket`), and the user lands on the
  key's project.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.{UsersFixtures, ProjectsFixtures}

  alias CodeMySpec.ExternalUsers.ExternalUser

  @deploy_key :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)

  setup %{conn: conn} do
    scope = full_scope_fixture()
    project = project_fixture(scope, %{deploy_key: @deploy_key})

    conn = put_req_header(conn, "accept", "application/json")

    {:ok, conn: conn, scope: scope, project: project}
  end

  describe "POST /api/widget/users" do
    test "valid deploy key upserts the user onto the key's project", %{
      conn: conn,
      project: project
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@deploy_key}")
        |> post(~p"/api/widget/users", %{
          "user" => %{
            "email" => "jane@example.com",
            "external_id" => "usr_42",
            "name" => "Jane",
            "metadata" => %{"platform" => "macos", "version" => "1.5.39"}
          }
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["email"] == "jane@example.com"
      assert data["external_id"] == "usr_42"
      assert data["name"] == "Jane"
      assert data["metadata"] == %{"platform" => "macos", "version" => "1.5.39"}
      assert data["project_id"] == project.id
    end

    test "repeat upsert refreshes the record instead of duplicating", %{conn: conn} do
      post_user = fn attrs ->
        conn
        |> put_req_header("authorization", "Bearer #{@deploy_key}")
        |> post(~p"/api/widget/users", %{"user" => attrs})
      end

      first = post_user.(%{"email" => "jane@example.com", "name" => "Jane"})
      assert %{"data" => %{"id" => id}} = json_response(first, 200)

      second =
        post_user.(%{
          "email" => "jane@example.com",
          "name" => "Jane D.",
          "external_id" => "usr_42"
        })

      assert %{"data" => data} = json_response(second, 200)
      assert data["id"] == id
      assert data["name"] == "Jane D."
      assert data["external_id"] == "usr_42"
      assert CodeMySpec.Repo.aggregate(ExternalUser, :count) == 1
    end

    test "unknown deploy key is rejected and stores nothing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{String.duplicate("f", 128)}")
        |> post(~p"/api/widget/users", %{"user" => %{"email" => "jane@example.com"}})

      assert %{"error" => "Invalid deploy key"} = json_response(conn, 401)
      assert CodeMySpec.Repo.aggregate(ExternalUser, :count) == 0
    end

    test "missing authorization header is rejected", %{conn: conn} do
      conn = post(conn, ~p"/api/widget/users", %{"user" => %{"email" => "jane@example.com"}})

      assert json_response(conn, 401)
    end

    test "invalid user params return 422", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@deploy_key}")
        |> post(~p"/api/widget/users", %{"user" => %{"name" => "no email"}})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "missing user param returns 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@deploy_key}")
        |> post(~p"/api/widget/users", %{})

      assert json_response(conn, 400)
    end
  end
end
