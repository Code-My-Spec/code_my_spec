defmodule CodeMySpecWeb.IssuesControllerTest do
  use CodeMySpecTest.ConnCase

  import CodeMySpec.{UsersFixtures, IssuesFixtures}

  setup %{conn: conn} do
    scope = full_preferences_fixture()
    oauth_app = create_oauth_application()

    access_token_value =
      :crypto.strong_rand_bytes(32) |> Base.encode64() |> String.replace(~r/[^a-zA-Z0-9]/, "")

    {1, [_token]} =
      CodeMySpec.Repo.insert_all(
        "oauth_access_tokens",
        [
          %{
            token: access_token_value,
            resource_owner_id: scope.user.id,
            application_id: oauth_app.id,
            scopes: "read write",
            expires_in: 7200,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ],
        returning: [:id, :token, :resource_owner_id]
      )

    conn =
      put_req_header(conn, "authorization", "Bearer #{access_token_value}")
      |> assign(:current_scope, scope)

    %{conn: conn, scope: scope}
  end

  defp create_oauth_application(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        name: "Test Application",
        uid: "test-client-#{System.unique_integer([:positive])}",
        secret: "test-secret-#{:crypto.strong_rand_bytes(32) |> Base.encode64()}",
        redirect_uri: "https://example.com/callback",
        scopes: "read write"
      })

    {1, [app]} =
      CodeMySpec.Repo.insert_all(
        "oauth_applications",
        [
          Map.merge(attrs, %{
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          })
        ],
        returning: [:id, :name, :uid, :secret, :redirect_uri, :scopes]
      )

    struct(CodeMySpec.Oauth.Application, app)
  end

  describe "index/2" do
    test "returns empty list when no issues", %{conn: conn} do
      conn = get(conn, ~p"/api/issues")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns list of issues", %{conn: conn, scope: scope} do
      issue = issue_fixture(scope)
      conn = get(conn, ~p"/api/issues")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == issue.id
      assert data["title"] == issue.title
      assert data["severity"] == to_string(issue.severity)
      assert data["status"] == "incoming"
    end

    test "filters by status", %{conn: conn, scope: scope} do
      issue_fixture(scope)
      conn = get(conn, ~p"/api/issues?status=accepted")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "filters by severity", %{conn: conn, scope: scope} do
      issue_fixture(scope, %{severity: :critical})
      issue_fixture(scope, %{severity: :low})

      conn = get(conn, ~p"/api/issues?severity=critical")

      data = json_response(conn, 200)["data"]
      assert length(data) == 1
      assert hd(data)["severity"] == "critical"
    end
  end

  describe "show/2" do
    test "returns issue by id", %{conn: conn, scope: scope} do
      issue = issue_fixture(scope)
      conn = get(conn, ~p"/api/issues/#{issue.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == issue.id
      assert data["title"] == issue.title
      assert data["description"] == issue.description
      assert data["severity"] == to_string(issue.severity)
      assert data["scope"] == to_string(issue.scope)
      assert data["status"] == "incoming"
      assert data["project_id"] == issue.project_id
      assert data["account_id"] == issue.account_id
    end

    test "returns 404 for non-existent issue", %{conn: conn} do
      conn = get(conn, ~p"/api/issues/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end

  describe "create/2" do
    test "creates issue with valid params", %{conn: conn} do
      params = %{
        title: "Button broken on mobile",
        description: "The submit button doesn't respond to taps on iOS Safari",
        severity: "high"
      }

      conn = post(conn, ~p"/api/issues", issue: params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Button broken on mobile"
      assert data["description"] == "The submit button doesn't respond to taps on iOS Safari"
      assert data["severity"] == "high"
      assert data["scope"] == "app"
      assert data["status"] == "incoming"
      assert data["id"]
    end

    test "creates issue with source field", %{conn: conn} do
      params = %{
        title: "Feedback from user",
        description: "Something is broken",
        severity: "medium",
        source: "user_feedback"
      }

      conn = post(conn, ~p"/api/issues", issue: params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["source"] == "user_feedback"
    end

    test "creates issue with all optional fields", %{conn: conn} do
      params = %{
        title: "QA found layout issue",
        description: "Sidebar overlaps content at 768px",
        severity: "medium",
        scope: "qa",
        story_id: 42
      }

      conn = post(conn, ~p"/api/issues", issue: params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["scope"] == "qa"
      assert data["story_id"] == 42
    end

    test "returns 422 with missing required fields", %{conn: conn} do
      conn = post(conn, ~p"/api/issues", issue: %{title: "No description"})

      assert json_response(conn, 422)
    end

    test "returns 422 with empty params", %{conn: conn} do
      conn = post(conn, ~p"/api/issues", issue: %{})

      assert json_response(conn, 422)
    end
  end
end
