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

  # The defect this covers: a deployed app holding only the short-lived
  # credential could register a visitor at /api/widget/users and then not file
  # that visitor's feedback here, because the users controller had been
  # migrated to AppCredential and this one still matched deploy keys only. An
  # app that can introduce someone and not hear from them is the feedback
  # widget failing at exactly the moment it matters.
  test "the short-lived access token files an issue, not just the deploy key", %{
    conn: conn,
    project: project
  } do
    # Through the real door: a deployed app holds a refresh secret and trades
    # it for the short-lived token, which is the credential under test.
    {:ok, project} = CodeMySpec.AppTokens.put_refresh_secret(project, "widget-issues-test-secret")
    {:ok, token, _expires_in} = CodeMySpec.AppTokens.exchange("widget-issues-test-secret")
    _ = project

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/widget/issues", %{
        "issue" => %{"title" => "Filed with a token", "description" => "Not a deploy key."}
      })

    assert %{"data" => issue} = json_response(conn, 201)
    assert issue["title"] == "Filed with a token"
  end

  # Auth before the parameter complaint. A 400 to a caller who never
  # authenticated reads as "your credential was fine, your body was not" — and
  # that is precisely how the credential defect above survived a QA pass.
  test "a bad credential is refused before the body is inspected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer not-a-real-credential")
      |> post(~p"/api/widget/issues", %{})

    assert json_response(conn, 401),
           "an unauthenticated caller must not learn the parameter shape, and must " <>
             "not be told its request body was the problem"
  end

  test "no credential is refused", %{conn: conn} do
    conn =
      post(conn, ~p"/api/widget/issues", %{"issue" => %{"title" => "x", "description" => "y"}})

    assert json_response(conn, 401),
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
