defmodule CodeMySpec.LocalServer.Controllers.IssuesControllerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.Issues.IssuesRepository
  alias CodeMySpec.LocalServer.Controllers.IssuesController

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  defp create_issue(scope, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Test issue #{System.unique_integer([:positive])}",
          severity: :high,
          scope: :app,
          description: "Something is broken"
        },
        overrides
      )

    {:ok, issue} = IssuesRepository.create_issue(scope, attrs)
    issue
  end

  # ============================================================================
  # Index
  # ============================================================================

  describe "index/1" do
    test "returns all issues for the project", %{scope: scope} do
      issue = create_issue(scope)

      conn = build_get(scope, "/api/issues")
      conn = IssuesController.index(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == 1
      assert [returned] = body["issues"]
      assert returned["id"] == issue.id
      assert returned["title"] == issue.title
      assert returned["severity"] == "high"
      assert returned["status"] == "incoming"
    end

    test "returns empty list when no issues exist", %{scope: scope} do
      conn = build_get(scope, "/api/issues")
      conn = IssuesController.index(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == 0
      assert body["issues"] == []
    end

    test "filters by status", %{scope: scope} do
      _incoming = create_issue(scope, %{title: "incoming one"})
      accepted = create_issue(scope, %{title: "accepted one"})
      IssuesRepository.update_status(accepted, :accepted)

      conn = build_get(scope, "/api/issues?status=accepted")
      conn = IssuesController.index(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == 1
      assert [returned] = body["issues"]
      assert returned["title"] == "accepted one"
    end

    test "filters by minimum severity", %{scope: scope} do
      _critical = create_issue(scope, %{title: "critical", severity: :critical})
      _high = create_issue(scope, %{title: "high", severity: :high})
      _low = create_issue(scope, %{title: "low", severity: :low})

      conn = build_get(scope, "/api/issues?severity=high")
      conn = IssuesController.index(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == 2
      titles = Enum.map(body["issues"], & &1["title"])
      assert "critical" in titles
      assert "high" in titles
      refute "low" in titles
    end

    test "filters by story_id", %{scope: scope} do
      _story1 = create_issue(scope, %{title: "story 1", story_id: 1})
      _story2 = create_issue(scope, %{title: "story 2", story_id: 2})

      conn = build_get(scope, "/api/issues?story_id=1")
      conn = IssuesController.index(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == 1
      assert [returned] = body["issues"]
      assert returned["title"] == "story 1"
    end

    test "filters by scope", %{scope: scope} do
      _app = create_issue(scope, %{title: "app issue", scope: :app})
      _qa = create_issue(scope, %{title: "qa issue", scope: :qa})

      conn = build_get(scope, "/api/issues?scope=qa")
      conn = IssuesController.index(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == 1
      assert [returned] = body["issues"]
      assert returned["title"] == "qa issue"
    end

    test "combines multiple filters", %{scope: scope} do
      _match = create_issue(scope, %{title: "match", severity: :high, story_id: 1})
      _no_match = create_issue(scope, %{title: "wrong story", severity: :high, story_id: 2})
      _low = create_issue(scope, %{title: "low sev", severity: :low, story_id: 1})

      conn = build_get(scope, "/api/issues?severity=high&story_id=1")
      conn = IssuesController.index(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == 1
      assert [returned] = body["issues"]
      assert returned["title"] == "match"
    end

    test "does not return issues from other projects", %{scope: scope} do
      other_scope = full_scope_fixture()
      _my_issue = create_issue(scope, %{title: "mine"})
      _other_issue = create_issue(other_scope, %{title: "theirs"})

      conn = build_get(scope, "/api/issues")
      conn = IssuesController.index(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == 1
      assert [returned] = body["issues"]
      assert returned["title"] == "mine"
    end
  end

  # ============================================================================
  # Show
  # ============================================================================

  describe "show/1" do
    test "returns a single issue", %{scope: scope} do
      issue = create_issue(scope, %{story_id: 42, source_path: "test/file.ex"})

      conn = build_get(scope, "/api/issues/#{issue.id}", %{"id" => issue.id})
      conn = IssuesController.show(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned = body["issue"]
      assert returned["id"] == issue.id
      assert returned["title"] == issue.title
      assert returned["severity"] == "high"
      assert returned["scope"] == "app"
      assert returned["status"] == "incoming"
      assert returned["description"] == "Something is broken"
      assert returned["story_id"] == 42
      assert returned["source_path"] == "test/file.ex"
      assert returned["inserted_at"] != nil
    end

    test "returns 404 for non-existent issue", %{scope: scope} do
      fake_id = Ecto.UUID.generate()

      conn = build_get(scope, "/api/issues/#{fake_id}", %{"id" => fake_id})
      conn = IssuesController.show(conn)

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Issue not found"
    end

    test "returns 404 for issue belonging to another project", %{scope: scope} do
      other_scope = full_scope_fixture()
      other_issue = create_issue(other_scope)

      conn = build_get(scope, "/api/issues/#{other_issue.id}", %{"id" => other_issue.id})
      conn = IssuesController.show(conn)

      assert conn.status == 404
    end
  end

  # ============================================================================
  # Create
  # ============================================================================

  describe "create/1" do
    test "creates an issue with required fields", %{scope: scope} do
      params = %{
        "title" => "New bug",
        "severity" => "high",
        "description" => "It's broken"
      }

      conn = build_post(scope, "/api/issues", params)
      conn = IssuesController.create(conn)

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      returned = body["issue"]
      assert returned["title"] == "New bug"
      assert returned["severity"] == "high"
      assert returned["scope"] == "app"
      assert returned["status"] == "incoming"
      assert returned["description"] == "It's broken"
    end

    test "creates an issue with all optional fields", %{scope: scope} do
      params = %{
        "title" => "Full issue",
        "severity" => "critical",
        "description" => "Very broken",
        "scope" => "qa",
        "story_id" => 99,
        "source_path" => "test/qa.ex"
      }

      conn = build_post(scope, "/api/issues", params)
      conn = IssuesController.create(conn)

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      returned = body["issue"]
      assert returned["scope"] == "qa"
      assert returned["story_id"] == 99
      assert returned["source_path"] == "test/qa.ex"
    end

    test "returns 422 when required fields are missing", %{scope: scope} do
      params = %{"title" => "No severity or description"}

      conn = build_post(scope, "/api/issues", params)
      conn = IssuesController.create(conn)

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "severity"
    end
  end

  # ============================================================================
  # Accept
  # ============================================================================

  describe "accept/1" do
    test "accepts an incoming issue", %{scope: scope} do
      issue = create_issue(scope)

      conn = build_post(scope, "/api/issues/#{issue.id}/accept", %{}, %{"id" => issue.id})
      conn = IssuesController.accept(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["issue"]["status"] == "accepted"
    end

    test "returns 404 for non-existent issue", %{scope: scope} do
      fake_id = Ecto.UUID.generate()

      conn = build_post(scope, "/api/issues/#{fake_id}/accept", %{}, %{"id" => fake_id})
      conn = IssuesController.accept(conn)

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Issue not found"
    end

    test "returns 422 for invalid transition", %{scope: scope} do
      issue = create_issue(scope)
      {:ok, issue} = IssuesRepository.update_status(issue, :accepted)
      {:ok, _issue} = IssuesRepository.update_status(issue, :resolved, "Fixed it")

      conn = build_post(scope, "/api/issues/#{issue.id}/accept", %{}, %{"id" => issue.id})
      conn = IssuesController.accept(conn)

      assert conn.status == 422
    end
  end

  # ============================================================================
  # Dismiss
  # ============================================================================

  describe "dismiss/1" do
    test "dismisses an incoming issue with reason", %{scope: scope} do
      issue = create_issue(scope)

      conn =
        build_post(scope, "/api/issues/#{issue.id}/dismiss", %{"reason" => "Not a bug"}, %{
          "id" => issue.id
        })

      conn = IssuesController.dismiss(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["issue"]["status"] == "dismissed"
      assert body["issue"]["resolution"] == "Not a bug"
    end

    test "returns 422 when reason is missing", %{scope: scope} do
      issue = create_issue(scope)

      conn = build_post(scope, "/api/issues/#{issue.id}/dismiss", %{}, %{"id" => issue.id})
      conn = IssuesController.dismiss(conn)

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "reason"
    end

    test "returns 422 when reason is empty string", %{scope: scope} do
      issue = create_issue(scope)

      conn =
        build_post(scope, "/api/issues/#{issue.id}/dismiss", %{"reason" => ""}, %{
          "id" => issue.id
        })

      conn = IssuesController.dismiss(conn)

      assert conn.status == 422
    end

    test "returns 404 for non-existent issue", %{scope: scope} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_post(scope, "/api/issues/#{fake_id}/dismiss", %{"reason" => "Gone"}, %{
          "id" => fake_id
        })

      conn = IssuesController.dismiss(conn)

      assert conn.status == 404
    end
  end

  # ============================================================================
  # Resolve
  # ============================================================================

  describe "resolve/1" do
    test "resolves an accepted issue with resolution", %{scope: scope} do
      issue = create_issue(scope)
      {:ok, accepted} = IssuesRepository.update_status(issue, :accepted)

      conn =
        build_post(
          scope,
          "/api/issues/#{accepted.id}/resolve",
          %{"resolution" => "Fixed in commit abc123"},
          %{"id" => accepted.id}
        )

      conn = IssuesController.resolve(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["issue"]["status"] == "resolved"
      assert body["issue"]["resolution"] == "Fixed in commit abc123"
    end

    test "returns 422 when resolution is missing", %{scope: scope} do
      issue = create_issue(scope)
      {:ok, accepted} = IssuesRepository.update_status(issue, :accepted)

      conn =
        build_post(scope, "/api/issues/#{accepted.id}/resolve", %{}, %{"id" => accepted.id})

      conn = IssuesController.resolve(conn)

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "resolution"
    end

    test "returns 422 for invalid transition (incoming -> resolved)", %{scope: scope} do
      issue = create_issue(scope)

      conn =
        build_post(
          scope,
          "/api/issues/#{issue.id}/resolve",
          %{"resolution" => "Fixed"},
          %{"id" => issue.id}
        )

      conn = IssuesController.resolve(conn)

      assert conn.status == 422
    end

    test "returns 404 for non-existent issue", %{scope: scope} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_post(
          scope,
          "/api/issues/#{fake_id}/resolve",
          %{"resolution" => "Fixed"},
          %{"id" => fake_id}
        )

      conn = IssuesController.resolve(conn)

      assert conn.status == 404
    end
  end

  # ============================================================================
  # JSON serialization
  # ============================================================================

  describe "serialization" do
    test "serializes all fields correctly", %{scope: scope} do
      issue =
        create_issue(scope, %{
          title: "Serialize test",
          severity: :critical,
          scope: :qa,
          description: "Details here",
          story_id: 7,
          source_path: "lib/foo.ex"
        })

      conn = build_get(scope, "/api/issues/#{issue.id}", %{"id" => issue.id})
      conn = IssuesController.show(conn)

      body = Jason.decode!(conn.resp_body)
      returned = body["issue"]

      assert returned["id"] == issue.id
      assert returned["title"] == "Serialize test"
      assert returned["severity"] == "critical"
      assert returned["scope"] == "qa"
      assert returned["status"] == "incoming"
      assert returned["description"] == "Details here"
      assert returned["resolution"] == nil
      assert returned["story_id"] == 7
      assert returned["source_path"] == "lib/foo.ex"
      assert is_binary(returned["inserted_at"])
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_get(scope, path, path_params \\ %{}) do
    conn(:get, path)
    |> assign(:current_scope, scope)
    |> Map.put(:path_params, path_params)
  end

  defp build_post(scope, path, body_params, path_params \\ %{}) do
    conn(:post, path, Jason.encode!(body_params))
    |> put_req_header("content-type", "application/json")
    |> assign(:current_scope, scope)
    |> Map.put(:body_params, body_params)
    |> Map.put(:path_params, path_params)
  end
end
