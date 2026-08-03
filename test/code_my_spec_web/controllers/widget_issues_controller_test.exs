defmodule CodeMySpecWeb.WidgetIssuesControllerTest do
  @moduledoc """
  An end user of a generated app files an issue without an account.

  Two QA drills reported the feedback widget rendering fine and failing only on
  submit, because it filed through the OAuth path and the project had no client
  credentials. That is the worst shape for the failure — it looks like it works
  until someone actually has something to say.

  The deploy key authenticates the *app*. The reporter is anonymous by design.
  """

  use CodeMySpecTest.ConnCase

  import CodeMySpec.{UsersFixtures, ProjectsFixtures}

  @deploy_key :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)

  setup %{conn: conn} do
    scope = full_scope_fixture()
    project = project_fixture(scope, %{deploy_key: @deploy_key})

    %{conn: put_req_header(conn, "accept", "application/json"), project: project}
  end

  test "an anonymous reporter files an issue with the app's deploy key", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@deploy_key}")
      |> post(~p"/api/widget/issues", %{
        "issue" => %{"title" => "Delete has no confirmation", "description" => "Lost a task."}
      })

    assert %{"data" => issue} = json_response(conn, 201)
    assert issue["title"] == "Delete has no confirmation"
  end

  test "no credential is refused", %{conn: conn} do
    conn =
      post(conn, ~p"/api/widget/issues", %{"issue" => %{"title" => "x", "description" => "y"}})

    assert json_response(conn, 401)["error"] =~ "deploy key",
           "anonymous means no *reporter* login — the app still has to say which " <>
             "project this is, or anyone could file against anyone"
  end

  test "a wrong deploy key is refused", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer not-a-real-key")
      |> post(~p"/api/widget/issues", %{"issue" => %{"title" => "x", "description" => "y"}})

    assert json_response(conn, 401)
  end

  test "a missing issue payload is a bad request, not a crash", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@deploy_key}")
      |> post(~p"/api/widget/issues", %{})

    assert json_response(conn, 400)["error"] =~ "issue"
  end
end
