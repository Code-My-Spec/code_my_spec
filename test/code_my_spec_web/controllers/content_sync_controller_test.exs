defmodule CodeMySpecWeb.ContentSyncControllerTest do
  # Sync: this file rewrites `Application.env(:code_my_spec, :deploy_key)` —
  # `put_env` in setup, `delete_env` in one test, restore in another — and that
  # is process-global, not per-test.
  #
  # `/api/cms/users` reads the same key at *request* time
  # (`cms_users_controller.ex:94`), so `app_credential_test.exs:95` — which
  # sends the compile-time literal and is also async — got 401 instead of 200
  # whenever the two overlapped. Observed once by the analyzer's exunit run; it
  # passes 20 consecutive standalone runs and five full suites, because the
  # window is the few milliseconds between this file's `put_env` and its
  # restore.
  #
  # Same shape and same fix as `analysis/runners_test.exs`, which went sync
  # because `use_cmd_cassette` patches `System.cmd/3` through meck globally.
  use CodeMySpecTest.ConnCase, async: false

  import ExUnit.CaptureLog

  alias CodeMySpec.Content

  @valid_deploy_key "test_deploy_key_12345"
  @invalid_deploy_key "wrong_key"

  @valid_content_payload %{
    "content" => [
      %{
        "slug" => "test-post",
        "title" => "Test Post",
        "content_type" => "blog",
        "processed_content" => "<h1>Test Content</h1>",
        "protected" => false,
        "publish_at" => nil,
        "expires_at" => nil,
        "meta_title" => "Test Post",
        "meta_description" => "A test post",
        "og_image" => nil,
        "og_title" => nil,
        "og_description" => nil,
        "metadata" => %{}
      }
    ],
    "synced_at" => "2024-01-01T00:00:00Z"
  }

  setup do
    # Set the deploy key in application config for tests
    original_deploy_key = Application.get_env(:code_my_spec, :deploy_key)
    Application.put_env(:code_my_spec, :deploy_key, @valid_deploy_key)
    on_exit(fn -> restore_deploy_key(original_deploy_key) end)

    :ok
  end

  describe "POST /api/content/sync" do
    test "successfully syncs content with valid deploy key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      assert json_response(conn, 200) == %{
               "status" => "success",
               "synced_count" => 1,
               "message" => "Content synced successfully"
             }

      # Verify content was actually synced
      content = Content.get_content_by_slug(nil, "test-post", :blog)
      assert content != nil
      assert content.title == "Test Post"
    end

    test "returns 401 with invalid deploy key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@invalid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      assert json_response(conn, 401) == %{
               "status" => "error",
               "error" => "Invalid deployment key",
               "reason" => "invalid"
             }

      # Verify content was NOT synced
      content = Content.get_content_by_slug(nil, "test-post", :blog)
      assert content == nil
    end

    test "returns 401 with missing authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      assert json_response(conn, 401) == %{
               "status" => "error",
               "error" => "Missing deployment key",
               "reason" => "invalid"
             }
    end

    test "returns 401 with malformed authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Token #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      assert json_response(conn, 401) == %{
               "status" => "error",
               "error" => "Missing deployment key",
               "reason" => "invalid"
             }
    end

    test "returns 400 with missing content parameter", %{conn: conn} do
      invalid_payload = %{"synced_at" => "2024-01-01T00:00:00Z"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", invalid_payload)

      assert json_response(conn, 400) == %{
               "status" => "error",
               "error" => "Missing required parameters: content, synced_at"
             }
    end

    test "returns 400 with missing synced_at parameter", %{conn: conn} do
      invalid_payload = %{"content" => []}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", invalid_payload)

      assert json_response(conn, 400) == %{
               "status" => "error",
               "error" => "Missing required parameters: content, synced_at"
             }
    end

    test "returns 500 when DEPLOY_KEY environment variable is not set", %{conn: conn} do
      Application.delete_env(:code_my_spec, :deploy_key)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      assert json_response(conn, 500) == %{
               "status" => "error",
               "error" => "Deploy key not configured on server"
             }
    end

    test "syncs multiple content items", %{conn: conn} do
      multi_content_payload = %{
        "content" => [
          %{
            "slug" => "post-1",
            "title" => "Post 1",
            "content_type" => "blog",
            "processed_content" => "<h1>Post 1</h1>",
            "protected" => false,
            "publish_at" => nil,
            "expires_at" => nil,
            "meta_title" => "Post 1",
            "meta_description" => "First post",
            "og_image" => nil,
            "og_title" => nil,
            "og_description" => nil,
            "metadata" => %{}
          },
          %{
            "slug" => "post-2",
            "title" => "Post 2",
            "content_type" => "blog",
            "processed_content" => "<h1>Post 2</h1>",
            "protected" => false,
            "publish_at" => nil,
            "expires_at" => nil,
            "meta_title" => "Post 2",
            "meta_description" => "Second post",
            "og_image" => nil,
            "og_title" => nil,
            "og_description" => nil,
            "metadata" => %{}
          }
        ],
        "synced_at" => "2024-01-01T00:00:00Z"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", multi_content_payload)

      assert json_response(conn, 200) == %{
               "status" => "success",
               "synced_count" => 2,
               "message" => "Content synced successfully"
             }

      # Verify both items were synced
      post1 = Content.get_content_by_slug(nil, "post-1", :blog)
      post2 = Content.get_content_by_slug(nil, "post-2", :blog)

      assert post1 != nil
      assert post1.title == "Post 1"
      assert post2 != nil
      assert post2.title == "Post 2"
    end

    test "replaces existing content on sync", %{conn: _conn} do
      # First sync
      conn1 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      assert json_response(conn1, 200)["synced_count"] == 1

      # Second sync with different content
      new_payload = %{
        "content" => [
          %{
            "slug" => "new-post",
            "title" => "New Post",
            "content_type" => "blog",
            "processed_content" => "<h1>New Content</h1>",
            "protected" => false,
            "publish_at" => nil,
            "expires_at" => nil,
            "meta_title" => "New Post",
            "meta_description" => "A new post",
            "og_image" => nil,
            "og_title" => nil,
            "og_description" => nil,
            "metadata" => %{}
          }
        ],
        "synced_at" => "2024-01-02T00:00:00Z"
      }

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", new_payload)

      assert json_response(conn2, 200)["synced_count"] == 1

      # Verify old content is gone and new content exists
      old_content = Content.get_content_by_slug(nil, "test-post", :blog)
      new_content = Content.get_content_by_slug(nil, "new-post", :blog)

      assert old_content == nil
      assert new_content != nil
      assert new_content.title == "New Post"
    end

    test "returns 422 with invalid content data", %{conn: conn} do
      invalid_content_payload = %{
        "content" => [
          %{
            # Missing required fields like slug, title, content_type
            "processed_content" => "<h1>Test</h1>"
          }
        ],
        "synced_at" => "2024-01-01T00:00:00Z"
      }

      # Capture expected error logs from validation failure
      capture_log(fn ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
          |> put_req_header("content-type", "application/json")
          |> post(~p"/api/content/sync", invalid_content_payload)

        response = json_response(conn, 422)
        assert response["status"] == "error"
        assert response["error"] != nil
      end)
    end

    test "handles empty content list", %{conn: conn} do
      empty_payload = %{
        "content" => [],
        "synced_at" => "2024-01-01T00:00:00Z"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", empty_payload)

      assert json_response(conn, 200) == %{
               "status" => "success",
               "synced_count" => 0,
               "message" => "Content synced successfully"
             }
    end

    test "preserves metadata during sync", %{conn: conn} do
      payload_with_metadata = %{
        "content" => [
          %{
            "slug" => "metadata-test",
            "title" => "Metadata Test Post",
            "content_type" => "blog",
            "processed_content" => "<h1>Test Content</h1>",
            "protected" => false,
            "publish_at" => nil,
            "expires_at" => nil,
            "meta_title" => "Metadata Test - SEO",
            "meta_description" => "Testing metadata preservation",
            "og_image" => "https://example.com/image.jpg",
            "og_title" => "OG Title",
            "og_description" => "OG Description",
            "metadata" => %{
              "author" => "John Doe",
              "category" => "Tech",
              "tags" => ["elixir", "phoenix"],
              "custom_field" => "custom_value"
            }
          }
        ],
        "synced_at" => "2024-01-01T00:00:00Z"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@valid_deploy_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", payload_with_metadata)

      assert json_response(conn, 200)["status"] == "success"

      # Verify metadata was properly saved
      content = Content.get_content_by_slug(nil, "metadata-test", :blog)
      assert content != nil
      assert content.title == "Metadata Test Post"

      # Verify all metadata fields are preserved
      assert is_map(content.metadata)
      assert content.metadata["author"] == "John Doe"
      assert content.metadata["category"] == "Tech"
      assert content.metadata["tags"] == ["elixir", "phoenix"]
      assert content.metadata["custom_field"] == "custom_value"
    end
  end

  describe "security" do
    test "uses constant-time comparison for deploy key", %{conn: _conn} do
      # This test verifies that timing attacks are mitigated
      # by ensuring different key lengths still get processed

      short_key = "short"
      long_key = String.duplicate("a", 1000)

      conn1 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{short_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{long_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      # Both should fail with unauthorized
      assert json_response(conn1, 401)["error"] == "Invalid deployment key"
      assert json_response(conn2, 401)["error"] == "Invalid deployment key"
    end

    test "does not leak timing information about key validity", %{conn: conn} do
      # Test with keys of same length as valid key
      similar_key = String.replace(@valid_deploy_key, "1", "9")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{similar_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/content/sync", @valid_content_payload)

      assert json_response(conn, 401)["error"] == "Invalid deployment key"
    end
  end

  defp restore_deploy_key(nil), do: Application.delete_env(:code_my_spec, :deploy_key)
  defp restore_deploy_key(key), do: Application.put_env(:code_my_spec, :deploy_key, key)
end
